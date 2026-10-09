//
//  MeshImportKit.swift
//  openshape3d
//
//  Mesh import for the formats a downloaded model actually comes in — glTF
//  (.glb / .gltf), USDZ, and OBJ with its MTL and textures, alone or inside a
//  zip. Every path lands in the same `ImportedPart`: a RenderMesh that keeps
//  its texture coordinates, plus a BodyMaterialSpec carrying the base colour
//  and, when the file has one, the encoded albedo image. Geometry that arrives
//  with a texture keeps its own vertex splits (a UV seam is a real seam), so
//  no welding happens here; untextured parts weld like an STL would.
//
//  Units: glTF is metres by specification and is scaled to the app's
//  millimetres (×1000); USD defaults to centimetres (×10) unless a text
//  layer declares `metersPerUnit`; OBJ is unitless and taken 1:1 — each
//  scale is a parameter so a caller with better knowledge can override it.
//

import Compression
import Foundation
import ImageIO
import ModelIO
import UniformTypeIdentifiers
import simd

/// One body-to-be from an imported file.
nonisolated struct ImportedPart: Sendable {
    var name: String
    var mesh: RenderMesh
    var material: BodyMaterialSpec?
}

nonisolated enum MeshImportError: Error, Equatable {
    case unsupportedFormat(String)
    case malformed(String)
    case empty
}

/// A length unit a mesh file may have been authored in (Shapr3D's import
/// prompt offers the same five).
nonisolated enum MeshImportUnit: String, CaseIterable, Identifiable, Sendable {
    case millimetres, centimetres, metres, inches, feet

    var id: String { rawValue }

    var millimetresPerUnit: Double {
        switch self {
        case .millimetres: return 1
        case .centimetres: return 10
        case .metres: return 1000
        case .inches: return 25.4
        case .feet: return 304.8
        }
    }

    var label: String {
        switch self {
        case .millimetres: return "Millimetres"
        case .centimetres: return "Centimetres"
        case .metres: return "Metres"
        case .inches: return "Inches"
        case .feet: return "Feet"
        }
    }

    var abbreviation: String {
        switch self {
        case .millimetres: return "mm"
        case .centimetres: return "cm"
        case .metres: return "m"
        case .inches: return "in"
        case .feet: return "ft"
        }
    }

    /// The unit whose scale is closest (in ratio) to `scale` mm per unit.
    static func nearest(toScale scale: Double) -> MeshImportUnit {
        guard scale > 0, scale.isFinite else { return .millimetres }
        return allCases.min { abs(log($0.millimetresPerUnit / scale)) < abs(log($1.millimetresPerUnit / scale)) }!
    }

    /// "mm", "cm", "m", "in", "ft" and the usual spellings.
    static func parse(_ text: String) -> MeshImportUnit? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mm", "millimetre", "millimetres", "millimeter", "millimeters": return .millimetres
        case "cm", "centimetre", "centimetres", "centimeter", "centimeters": return .centimetres
        case "m", "metre", "metres", "meter", "meters": return .metres
        case "in", "inch", "inches", "\"": return .inches
        case "ft", "foot", "feet", "'": return .feet
        default: return nil
        }
    }
}

/// A parsed mesh file BEFORE units are applied: the parts in the file's own
/// units, what the format declares (if anything), and the guess a silent
/// import would make. The import prompt shows the model's size under each
/// unit from this; `MeshImportKit.scaled` applies the choice.
nonisolated struct MeshImportProbe: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    /// "OBJ", "STL", "glTF", "GLB", "USDZ", "Blender" — for the prompt's note.
    let format: String
    /// Parts in the FILE's units (unscaled).
    let parts: [ImportedPart]
    /// Bounding-box size in file units.
    let rawExtent: SIMD3<Float>
    let triangleCount: Int
    /// Millimetres per file unit a silent import applies: the declared unit
    /// for glTF/USD/Blender, the size heuristic for OBJ and STL.
    let detectedScale: Double
    /// The format records its unit (glTF, USD, Blender); false for OBJ/STL.
    let unitIsDeclared: Bool

    /// The prompt's preselection: the unit nearest `detectedScale`.
    var detectedUnit: MeshImportUnit { MeshImportUnit.nearest(toScale: detectedScale) }

    func extentMillimetres(for unit: MeshImportUnit) -> SIMD3<Double> {
        SIMD3<Double>(rawExtent) * unit.millimetresPerUnit
    }

    /// "4.75 × 1.96 × 2.69 m" or "47.00 × 47.00 × 47.00 mm": metres once the
    /// longest side reaches a metre, millimetres otherwise, two decimals.
    func sizeDescription(for unit: MeshImportUnit) -> String {
        let mm = extentMillimetres(for: unit)
        let longest = max(mm.x, mm.y, mm.z)
        let (divisor, suffix) = longest >= 1000 ? (1000.0, "m") : (1.0, "mm")
        return String(format: "%.2f × %.2f × %.2f %@",
                      mm.x / divisor, mm.y / divisor, mm.z / divisor, suffix)
    }

    /// One sentence for the prompt about how sure the detection is.
    var unitNote: String {
        if unitIsDeclared {
            return "\(format) files record their unit, and the detected choice matches the file. Change it only if you know the exporter got it wrong."
        }
        return "\(format) files don't record a unit. The detected choice is a guess from the model's size — pick the unit the file was made in."
    }
}

nonisolated enum MeshImportKit {
    /// Parts from `data` named `fileName`, in millimetres. `siblings` are
    /// other files that travelled with it (a zip's entries, keyed by their
    /// path inside the archive), where an OBJ's .mtl and textures or a
    /// .gltf's buffers live. `unitScale` (mm per file unit) overrides the
    /// detected unit — the import prompt's choice, or the bridge's `units`.
    static func parts(from data: Data, fileName: String,
                      siblings: [String: Data] = [:],
                      unitScale: Double? = nil) throws -> [ImportedPart] {
        let probe = try probe(data: data, fileName: fileName, siblings: siblings)
        return scaled(probe.parts, by: unitScale ?? probe.detectedScale)
    }

    /// Parse without applying units (see `MeshImportProbe`).
    static func probe(data: Data, fileName: String,
                      siblings: [String: Data] = [:]) throws -> MeshImportProbe {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let parts: [ImportedPart]
        let declaredScale: Double?
        let format: String
        switch ext {
        case "glb", "gltf":
            parts = try GLTFImporter.parts(from: data, isBinary: ext == "glb",
                                           siblings: siblings, unitScale: 1)
            declaredScale = 1000   // glTF is metres by specification
            format = ext == "glb" ? "GLB" : "glTF"
        case "usdz", "usd", "usda", "usdc":
            parts = try USDImporter.parts(from: data, fileName: fileName, unitScale: 1)
            declaredScale = USDImporter.unitScale(of: data, ext: ext)
            format = ext == "usdz" ? "USDZ" : "USD"
        case "obj":
            parts = try OBJTexturedImporter.parts(from: data, siblings: siblings, unitScale: 1)
            declaredScale = nil
            format = "OBJ"
        case "stl":
            let mesh: RenderMesh
            do { mesh = try STLImporter.importSTL(data) } catch {
                throw MeshImportError.malformed("not a valid STL file")
            }
            let stem = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
            parts = [ImportedPart(name: stem.isEmpty ? "Part" : stem, mesh: mesh, material: nil)]
            declaredScale = nil
            format = "STL"
        case "blend":
            parts = try BlendImporter.parts(from: data, siblings: siblings, unitScale: 1)
            declaredScale = 1000   // Blender scenes are metres at unit scale 1
            format = "Blender"
        case "zip":
            let entries = try ZipReader.entries(in: data)
            // The archive's payload file, by preference: a self-contained
            // scene first, then the OBJ (its MTL/textures ride as siblings).
            let order = ["glb", "gltf", "usdz", "obj", "blend", "stl"]
            for wanted in order {
                if let (path, bytes) = entries.first(where: {
                    ($0.key as NSString).pathExtension.lowercased() == wanted
                        && !($0.key as NSString).lastPathComponent.hasPrefix(".")
                }) {
                    // Bodies take the ARCHIVE's name, not the payload's
                    // ("Untitled_Scan…", not "textured_output").
                    let inner = try probe(data: bytes, fileName: path, siblings: entries)
                    return MeshImportProbe(
                        fileName: (fileName as NSString).lastPathComponent, format: inner.format,
                        parts: inner.parts, rawExtent: inner.rawExtent,
                        triangleCount: inner.triangleCount, detectedScale: inner.detectedScale,
                        unitIsDeclared: inner.unitIsDeclared)
                }
            }
            throw MeshImportError.unsupportedFormat("zip without a .glb, .gltf, .usdz, .obj, .blend or .stl inside")
        default:
            throw MeshImportError.unsupportedFormat(ext)
        }
        let live = parts.filter { $0.mesh.indices.count >= 3 }
        guard let extent = overallExtentVector(of: live) else { throw MeshImportError.empty }
        let longest = Double(max(extent.x, extent.y, extent.z))
        // No unit in OBJ/STL: a whole model under 10 units across is metres
        // (a LiDAR room scan is 3–8 m; a 4.7 m scan came in as a 4.7 mm
        // object while this threshold was 2). The prompt lets the user
        // overrule the guess before anything is built.
        let detected = declaredScale ?? ((longest > 0 && longest < 10) ? 1000 : 1)
        return MeshImportProbe(
            fileName: (fileName as NSString).lastPathComponent, format: format, parts: live,
            rawExtent: extent, triangleCount: live.reduce(0) { $0 + $1.mesh.triangleCount },
            detectedScale: detected, unitIsDeclared: declaredScale != nil)
    }

    /// Every part's positions multiplied by `factor` (mm per file unit).
    static func scaled(_ parts: [ImportedPart], by factor: Double) -> [ImportedPart] {
        guard factor != 1 else { return parts }
        let f = Float(factor)
        return parts.map { part in
            var scaled = part
            for i in scaled.mesh.positions.indices { scaled.mesh.positions[i] *= f }
            return scaled
        }
    }

    /// Bounding-box size of every part combined, in the parts' units.
    static func overallExtentVector(of parts: [ImportedPart]) -> SIMD3<Float>? {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for part in parts where !part.mesh.positions.isEmpty {
            let aabb = part.mesh.localAABB
            lo = simd_min(lo, aabb.min); hi = simd_max(hi, aabb.max)
        }
        guard lo.x.isFinite else { return nil }
        return hi - lo
    }

    /// The longest side of every part's combined bounding box.
    static func overallExtent(of parts: [ImportedPart]) -> Float? {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for part in parts where !part.mesh.positions.isEmpty {
            let aabb = part.mesh.localAABB
            lo = simd_min(lo, aabb.min); hi = simd_max(hi, aabb.max)
        }
        guard lo.x.isFinite else { return nil }
        return (hi - lo).max()
    }

    /// Files that sit beside `url` (and one folder down, for textures/), for
    /// callers that can read the directory — the DEBUG bridge, or a file
    /// opened in place on the Mac. An OBJ's .mtl and images, a .gltf's .bin,
    /// a .blend's unpacked textures all live there.
    static func folderSiblings(of url: URL, limitBytes: Int = 256 << 20) -> [String: Data] {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [:] }
        var out: [String: Data] = [:]
        var budget = limitBytes
        func add(_ file: URL, key: String) {
            guard file != url, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= budget, let data = try? Data(contentsOf: file) else { return }
            budget -= size
            out[key] = data
        }
        for entry in top {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                for inner in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    add(inner, key: "\(entry.lastPathComponent)/\(inner.lastPathComponent)")
                }
            } else {
                add(entry, key: entry.lastPathComponent)
            }
        }
        return out
    }

    /// Case-insensitive lookup of a referenced file among the siblings, by
    /// full relative path first, then by bare file name.
    static func sibling(_ reference: String, in siblings: [String: Data]) -> Data? {
        let ref = reference.removingPercentEncoding ?? reference
        let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
        if let hit = siblings.first(where: { $0.key.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return hit.value
        }
        let base = (cleaned as NSString).lastPathComponent
        return siblings.first {
            ($0.key as NSString).lastPathComponent.caseInsensitiveCompare(base) == .orderedSame
        }?.value
    }

    /// Smooth per-vertex normals from the triangle list, for files that ship
    /// none. Area-weighted, so large faces dominate their shared vertices.
    static func computedNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        return normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    /// PNG bytes for a CGImage (how ModelIO's decoded textures are stored).
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Zip (stored + deflate, enough for model archives)

nonisolated enum ZipReader {
    /// Every file entry, keyed by its path inside the archive.
    static func entries(in data: Data) throws -> [String: Data] {
        var out: [String: Data] = [:]
        // Walk local file headers (PK\3\4) from the front — model archives
        // are small and simple; the central directory would add nothing but
        // the ability to skip data descriptors, which these files rarely use.
        var offset = 0
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        // Sizes may be deferred to a data descriptor (flag bit 3); read them
        // from the central directory in that case.
        let central = centralSizes(bytes)
        while offset + 30 <= bytes.count, u32(offset) == 0x04034b50 {
            let flags = u16(offset + 6)
            let method = u16(offset + 8)
            var compressed = u32(offset + 18)
            var uncompressed = u32(offset + 22)
            let nameLength = u16(offset + 26)
            let extraLength = u16(offset + 28)
            let nameStart = offset + 30
            guard nameStart + nameLength <= bytes.count else { throw MeshImportError.malformed("zip: truncated name") }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            let dataStart = nameStart + nameLength + extraLength
            if flags & 0x08 != 0, let sizes = central[name] {
                compressed = sizes.compressed; uncompressed = sizes.uncompressed
            }
            guard dataStart + compressed <= bytes.count else { throw MeshImportError.malformed("zip: truncated entry \(name)") }
            let payload = Data(bytes[dataStart..<dataStart + compressed])
            if !name.hasSuffix("/") {
                switch method {
                case 0: out[name] = payload
                case 8: out[name] = try inflate(payload, expected: uncompressed)
                default: throw MeshImportError.malformed("zip: unsupported compression \(method) for \(name)")
                }
            }
            offset = dataStart + compressed
            if flags & 0x08 != 0 { offset += 16 } // data descriptor (with signature)
        }
        guard !out.isEmpty else { throw MeshImportError.malformed("zip: no entries") }
        return out
    }

    private static func centralSizes(_ bytes: [UInt8]) -> [String: (compressed: Int, uncompressed: Int)] {
        var sizes: [String: (Int, Int)] = [:]
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        // End-of-central-directory record: scan back for PK\5\6.
        var eocd = bytes.count - 22
        while eocd >= 0, !(bytes.count >= eocd + 4 && u32(eocd) == 0x06054b50) { eocd -= 1 }
        guard eocd >= 0 else { return sizes }
        var p = u32(eocd + 16)
        while p + 46 <= bytes.count, u32(p) == 0x02014b50 {
            let compressed = u32(p + 20), uncompressed = u32(p + 24)
            let n = u16(p + 28), e = u16(p + 30), c = u16(p + 32)
            guard p + 46 + n <= bytes.count else { break }
            let name = String(decoding: bytes[p + 46..<p + 46 + n], as: UTF8.self)
            sizes[name] = (compressed, uncompressed)
            p += 46 + n + e + c
        }
        return sizes
    }

    private static func inflate(_ data: Data, expected: Int) throws -> Data {
        let capacity = max(expected, 1)
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { throw MeshImportError.malformed("zip: inflate failed") }
        out.count = produced
        return out
    }
}

// MARK: - glTF 2.0 (.glb and .gltf)

nonisolated enum GLTFImporter {
    private static let magic: UInt32 = 0x46546C67
    private static let jsonChunk: UInt32 = 0x4E4F534A
    private static let binChunk: UInt32 = 0x004E4942

    static func parts(from data: Data, isBinary: Bool, siblings: [String: Data],
                      unitScale: Double) throws -> [ImportedPart] {
        var json: [String: Any]
        var binaryBuffer: Data?
        if isBinary {
            guard data.count >= 20 else { throw MeshImportError.malformed("glb: too short") }
            func u32(_ at: Int) -> UInt32 {
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
            }
            guard u32(0) == magic else { throw MeshImportError.malformed("glb: bad magic") }
            var offset = 12
            var jsonData: Data?
            while offset + 8 <= data.count {
                let length = Int(u32(offset)), type = u32(offset + 4)
                let start = offset + 8
                guard start + length <= data.count else { throw MeshImportError.malformed("glb: truncated chunk") }
                let chunk = data.subdata(in: start..<start + length)
                if type == jsonChunk { jsonData = chunk } else if type == binChunk { binaryBuffer = chunk }
                offset = start + length
            }
            guard let jsonData,
                  let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw MeshImportError.malformed("glb: no JSON chunk")
            }
            json = parsed
        } else {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MeshImportError.malformed("gltf: not a JSON object")
            }
            json = parsed
        }

        // Buffers: the GLB's BIN chunk, data: URIs, or files that came along.
        var buffers: [Data] = []
        for (i, entry) in ((json["buffers"] as? [[String: Any]]) ?? []).enumerated() {
            if let uri = entry["uri"] as? String {
                if let bytes = decodeDataURI(uri) ?? MeshImportKit.sibling(uri, in: siblings) {
                    buffers.append(bytes)
                } else {
                    throw MeshImportError.malformed("gltf: buffer \(i) '\(uri)' is not in the import")
                }
            } else if i == 0, let binaryBuffer {
                buffers.append(binaryBuffer)
            } else {
                throw MeshImportError.malformed("gltf: buffer \(i) has no data")
            }
        }
        let views = (json["bufferViews"] as? [[String: Any]]) ?? []
        let accessors = (json["accessors"] as? [[String: Any]]) ?? []
        let materials = (json["materials"] as? [[String: Any]]) ?? []
        let textures = (json["textures"] as? [[String: Any]]) ?? []
        let images = (json["images"] as? [[String: Any]]) ?? []
        let meshes = (json["meshes"] as? [[String: Any]]) ?? []
        let nodes = (json["nodes"] as? [[String: Any]]) ?? []

        func viewBytes(_ index: Int) throws -> (Data, stride: Int) {
            guard index < views.count else { throw MeshImportError.malformed("gltf: bufferView \(index)") }
            let view = views[index]
            let b = view["buffer"] as? Int ?? 0
            guard b < buffers.count else { throw MeshImportError.malformed("gltf: buffer \(b)") }
            let offset = view["byteOffset"] as? Int ?? 0
            let length = view["byteLength"] as? Int ?? 0
            guard offset + length <= buffers[b].count else { throw MeshImportError.malformed("gltf: bufferView \(index) overruns its buffer") }
            return (buffers[b].subdata(in: offset..<offset + length), view["byteStride"] as? Int ?? 0)
        }

        /// Accessor → floats (every component as Float, normalized types
        /// scaled to 0…1 / −1…1) plus the component count per element.
        func floats(_ index: Int) throws -> (values: [Float], components: Int, count: Int) {
            guard index < accessors.count else { throw MeshImportError.malformed("gltf: accessor \(index)") }
            let acc = accessors[index]
            let count = acc["count"] as? Int ?? 0
            let type = acc["type"] as? String ?? "SCALAR"
            let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][type] ?? 1
            let componentType = acc["componentType"] as? Int ?? 5126
            let normalized = acc["normalized"] as? Bool ?? false
            guard let viewIndex = acc["bufferView"] as? Int else {
                return ([Float](repeating: 0, count: count * components), components, count)
            }
            let (bytes, declaredStride) = try viewBytes(viewIndex)
            let base = acc["byteOffset"] as? Int ?? 0
            let size: Int
            switch componentType {
            case 5120, 5121: size = 1
            case 5122, 5123: size = 2
            default: size = 4
            }
            let stride = declaredStride > 0 ? declaredStride : size * components
            var out = [Float](); out.reserveCapacity(count * components)
            try bytes.withUnsafeBytes { raw in
                for e in 0..<count {
                    for c in 0..<components {
                        let at = base + e * stride + c * size
                        guard at + size <= raw.count else { throw MeshImportError.malformed("gltf: accessor \(index) overruns its view") }
                        let v: Float
                        switch componentType {
                        case 5120: let x = raw.load(fromByteOffset: at, as: Int8.self); v = normalized ? max(Float(x) / 127, -1) : Float(x)
                        case 5121: let x = raw.load(fromByteOffset: at, as: UInt8.self); v = normalized ? Float(x) / 255 : Float(x)
                        case 5122: let x = raw.loadUnaligned(fromByteOffset: at, as: Int16.self); v = normalized ? max(Float(x) / 32767, -1) : Float(x)
                        case 5123: let x = raw.loadUnaligned(fromByteOffset: at, as: UInt16.self); v = normalized ? Float(x) / 65535 : Float(x)
                        case 5125: v = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                        default: v = raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                        }
                        out.append(v)
                    }
                }
            }
            return (out, components, count)
        }

        func indices(_ index: Int) throws -> [UInt32] {
            guard index < accessors.count else { throw MeshImportError.malformed("gltf: index accessor \(index)") }
            let acc = accessors[index]
            let count = acc["count"] as? Int ?? 0
            let componentType = acc["componentType"] as? Int ?? 5125
            guard let viewIndex = acc["bufferView"] as? Int else { return [] }
            let (bytes, declaredStride) = try viewBytes(viewIndex)
            let base = acc["byteOffset"] as? Int ?? 0
            let size = componentType == 5121 ? 1 : componentType == 5123 ? 2 : 4
            let stride = declaredStride > 0 ? declaredStride : size
            var out = [UInt32](); out.reserveCapacity(count)
            try bytes.withUnsafeBytes { raw in
                for e in 0..<count {
                    let at = base + e * stride
                    guard at + size <= raw.count else { throw MeshImportError.malformed("gltf: indices overrun their view") }
                    switch size {
                    case 1: out.append(UInt32(raw.load(fromByteOffset: at, as: UInt8.self)))
                    case 2: out.append(UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                    default: out.append(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                    }
                }
            }
            return out
        }

        func imageBytes(_ imageIndex: Int) -> Data? {
            guard imageIndex < images.count else { return nil }
            let image = images[imageIndex]
            if let viewIndex = image["bufferView"] as? Int, let (bytes, _) = try? viewBytes(viewIndex) {
                return bytes
            }
            if let uri = image["uri"] as? String {
                return decodeDataURI(uri) ?? MeshImportKit.sibling(uri, in: siblings)
            }
            return nil
        }

        func material(_ index: Int?) -> BodyMaterialSpec? {
            guard let index, index < materials.count else { return nil }
            let m = materials[index]
            var spec = BodyMaterialSpec(baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.5)
            let pbr = m["pbrMetallicRoughness"] as? [String: Any]
            if let f = pbr?["baseColorFactor"] as? [Double], f.count == 4 {
                spec.baseColor = SIMD4(f[0], f[1], f[2], f[3])
            }
            if let metallic = pbr?["metallicFactor"] as? Double { spec.metallic = metallic }
            if let roughness = pbr?["roughnessFactor"] as? Double { spec.roughness = roughness }
            var textureIndex = (pbr?["baseColorTexture"] as? [String: Any])?["index"] as? Int
            if textureIndex == nil,
               let sg = (m["extensions"] as? [String: Any])?["KHR_materials_pbrSpecularGlossiness"] as? [String: Any] {
                textureIndex = (sg["diffuseTexture"] as? [String: Any])?["index"] as? Int
                if let f = sg["diffuseFactor"] as? [Double], f.count == 4 { spec.baseColor = SIMD4(f[0], f[1], f[2], f[3]) }
            }
            if let textureIndex, textureIndex < textures.count,
               let source = textures[textureIndex]["source"] as? Int {
                spec.baseColorTexture = imageBytes(source)
            }
            return spec
        }

        func localMatrix(_ node: [String: Any]) -> simd_double4x4 {
            if let m = node["matrix"] as? [Double], m.count == 16 {
                return simd_double4x4(columns: (
                    SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            }
            var out = matrix_identity_double4x4
            if let t = node["translation"] as? [Double], t.count == 3 {
                out.columns.3 = SIMD4(t[0], t[1], t[2], 1)
            }
            var rs = matrix_identity_double4x4
            if let r = node["rotation"] as? [Double], r.count == 4 {
                let q = simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3])
                rs = simd_double4x4(q)
            }
            if let s = node["scale"] as? [Double], s.count == 3 {
                rs = rs * simd_double4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
            }
            return out * rs
        }

        var parts: [ImportedPart] = []
        func emit(meshIndex: Int, world: simd_double4x4, nodeName: String?) throws {
            guard meshIndex < meshes.count else { return }
            let mesh = meshes[meshIndex]
            let meshName = mesh["name"] as? String
            let primitives = (mesh["primitives"] as? [[String: Any]]) ?? []
            for (pi, prim) in primitives.enumerated() {
                let mode = prim["mode"] as? Int ?? 4
                guard mode == 4 else { continue } // TRIANGLES only
                guard let attributes = prim["attributes"] as? [String: Any],
                      let positionAccessor = attributes["POSITION"] as? Int else { continue }
                let (p, pc, pcount) = try floats(positionAccessor)
                guard pc == 3, pcount > 0 else { continue }
                var idx: [UInt32]
                if let ia = prim["indices"] as? Int { idx = try indices(ia) } else { idx = (0..<UInt32(pcount)).map { $0 } }
                guard idx.count >= 3, idx.allSatisfy({ Int($0) < pcount }) else { continue }
                idx = Array(idx.prefix(idx.count - idx.count % 3))

                // Normal matrix: inverse-transpose of the upper 3×3.
                let m3 = simd_double3x3(
                    SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                    SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                    SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
                let nm = m3.inverse.transpose
                let mirrored = m3.determinant < 0

                var positions = [SIMD3<Float>](); positions.reserveCapacity(pcount)
                for i in 0..<pcount {
                    let v = world * SIMD4(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2]), 1)
                    positions.append(SIMD3<Float>(Float(v.x * unitScale), Float(v.y * unitScale), Float(v.z * unitScale)))
                }
                if mirrored { // keep the winding outward
                    for t in stride(from: 0, to: idx.count, by: 3) { idx.swapAt(t + 1, t + 2) }
                }
                var normals: [SIMD3<Float>]
                if let na = attributes["NORMAL"] as? Int, let (n, nc, ncount) = try? floats(na), nc == 3, ncount == pcount {
                    normals = (0..<pcount).map { i in
                        let v = nm * SIMD3(Double(n[i * 3]), Double(n[i * 3 + 1]), Double(n[i * 3 + 2]))
                        let len = simd_length(v)
                        return len > 1e-12 ? SIMD3<Float>(v / len) : SIMD3(0, 1, 0)
                    }
                } else {
                    normals = MeshImportKit.computedNormals(positions: positions, indices: idx)
                }
                var render = RenderMesh(positions: positions, normals: normals, indices: idx)
                if let ta = attributes["TEXCOORD_0"] as? Int, let (t, tc, tcount) = try? floats(ta), tc == 2, tcount == pcount {
                    // glTF's (0,0) is the image's top-left — Metal's too.
                    render.texcoords = (0..<pcount).map { SIMD2(t[$0 * 2], t[$0 * 2 + 1]) }
                }
                var spec = material(prim["material"] as? Int)
                if render.texcoords == nil { spec?.baseColorTexture = nil }
                let base = nodeName ?? meshName ?? "Part"
                let name = primitives.count > 1 ? "\(base) \(pi + 1)" : base
                parts.append(ImportedPart(name: name, mesh: render, material: spec))
            }
        }
        func visit(_ index: Int, parent: simd_double4x4, depth: Int) throws {
            guard index < nodes.count, depth < 64 else { return }
            let node = nodes[index]
            let world = parent * localMatrix(node)
            if let meshIndex = node["mesh"] as? Int {
                try emit(meshIndex: meshIndex, world: world, nodeName: node["name"] as? String)
            }
            for child in (node["children"] as? [Int]) ?? [] {
                try visit(child, parent: world, depth: depth + 1)
            }
        }
        let scenes = (json["scenes"] as? [[String: Any]]) ?? []
        let sceneIndex = json["scene"] as? Int ?? 0
        var roots: [Int] = sceneIndex < scenes.count ? ((scenes[sceneIndex]["nodes"] as? [Int]) ?? []) : []
        if roots.isEmpty {
            // No scene: every node nobody lists as a child is a root.
            var children = Set<Int>()
            for node in nodes { for c in (node["children"] as? [Int]) ?? [] { children.insert(c) } }
            roots = nodes.indices.filter { !children.contains($0) }
        }
        for root in roots { try visit(root, parent: matrix_identity_double4x4, depth: 0) }
        if parts.isEmpty, !meshes.isEmpty {
            // Meshes but no nodes referencing them (rare, but legal).
            for i in meshes.indices { try emit(meshIndex: i, world: matrix_identity_double4x4, nodeName: nil) }
        }
        guard !parts.isEmpty else { throw MeshImportError.empty }
        return parts
    }

    private static func decodeDataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.startIndex..<comma]
        let payload = String(uri[uri.index(after: comma)...])
        if header.hasSuffix(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }
}

// MARK: - OBJ with MTL and textures

nonisolated enum OBJTexturedImporter {
    private struct MTL {
        var color: SIMD4<Double> = SIMD4(0.8, 0.8, 0.8, 1)
        var texture: String?
    }

    static func parts(from data: Data, siblings: [String: Data], unitScale: Double) throws -> [ImportedPart] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw MeshImportError.malformed("obj: not text")
        }
        var positions: [SIMD3<Float>] = [], texcoords: [SIMD2<Float>] = [], normals: [SIMD3<Float>] = []
        var materials: [String: MTL] = [:]
        // A group being accumulated: corner tuples → vertex indices.
        struct Corner: Hashable { let v: Int, t: Int, n: Int }
        struct Builder {
            var name: String
            var materialName: String?
            var corners: [Corner: UInt32] = [:]
            var positions: [SIMD3<Float>] = [], texcoords: [SIMD2<Float>] = [], normals: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            var hasTexcoords = true, hasNormals = true
        }
        var builders: [Builder] = []
        var current = Builder(name: "Part")
        var groupName = "Part"
        var currentMaterial: String?
        func flush() {
            if !current.indices.isEmpty { builders.append(current) }
            current = Builder(name: groupName, materialName: currentMaterial)
        }
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = fields.first else { continue }
            switch key {
            case "v" where fields.count >= 4:
                positions.append(SIMD3(Float(fields[1]) ?? 0, Float(fields[2]) ?? 0, Float(fields[3]) ?? 0) * Float(unitScale))
            case "vt" where fields.count >= 3:
                // OBJ's origin is the image's bottom-left; the renderer's is top-left.
                texcoords.append(SIMD2(Float(fields[1]) ?? 0, 1 - (Float(fields[2]) ?? 0)))
            case "vn" where fields.count >= 4:
                normals.append(SIMD3(Float(fields[1]) ?? 0, Float(fields[2]) ?? 0, Float(fields[3]) ?? 0))
            case "o", "g":
                flush()
                groupName = fields.count > 1 ? fields.dropFirst().joined(separator: " ") : "Part"
                current.name = groupName
            case "usemtl":
                flush()
                currentMaterial = fields.count > 1 ? fields.dropFirst().joined(separator: " ") : nil
                current.materialName = currentMaterial
            case "mtllib":
                for name in fields.dropFirst() {
                    if let bytes = MeshImportKit.sibling(name, in: siblings) {
                        materials.merge(parseMTL(bytes)) { _, new in new }
                    }
                }
            case "f" where fields.count >= 4:
                var cornerIDs: [UInt32] = []
                for f in fields.dropFirst() {
                    let parts = f.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                    func resolve(_ s: String?, count: Int) -> Int {
                        guard let s, let i = Int(s) else { return -1 }
                        return i > 0 ? i - 1 : count + i
                    }
                    let v = resolve(parts.first, count: positions.count)
                    let t = resolve(parts.count > 1 ? parts[1] : nil, count: texcoords.count)
                    let n = resolve(parts.count > 2 ? parts[2] : nil, count: normals.count)
                    guard v >= 0, v < positions.count else { continue }
                    let corner = Corner(v: v, t: t, n: n)
                    if let existing = current.corners[corner] {
                        cornerIDs.append(existing)
                    } else {
                        let id = UInt32(current.positions.count)
                        current.corners[corner] = id
                        current.positions.append(positions[v])
                        if t >= 0, t < texcoords.count { current.texcoords.append(texcoords[t]) } else { current.hasTexcoords = false; current.texcoords.append(.zero) }
                        if n >= 0, n < normals.count { current.normals.append(normals[n]) } else { current.hasNormals = false; current.normals.append(.zero) }
                        cornerIDs.append(id)
                    }
                }
                // Fan-triangulate polygons.
                if cornerIDs.count >= 3 {
                    for k in 1..<(cornerIDs.count - 1) {
                        current.indices.append(contentsOf: [cornerIDs[0], cornerIDs[k], cornerIDs[k + 1]])
                    }
                }
            default:
                continue
            }
        }
        flush()
        guard !builders.isEmpty else { throw MeshImportError.empty }
        var parts: [ImportedPart] = []
        var used: [String: Int] = [:]
        for b in builders {
            var mesh = RenderMesh(positions: b.positions,
                                  normals: b.hasNormals ? b.normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
                                                        : MeshImportKit.computedNormals(positions: b.positions, indices: b.indices),
                                  indices: b.indices)
            var spec: BodyMaterialSpec?
            if let mname = b.materialName, let mtl = materials[mname] {
                spec = BodyMaterialSpec(baseColor: mtl.color, metallic: 0, roughness: 0.5)
                if b.hasTexcoords, let texName = mtl.texture, let bytes = MeshImportKit.sibling(texName, in: siblings) {
                    mesh.texcoords = b.texcoords
                    spec?.baseColorTexture = bytes
                }
            } else if b.hasTexcoords {
                mesh.texcoords = b.texcoords
            }
            var name = b.name
            if let m = b.materialName, builders.filter({ $0.name == b.name }).count > 1 { name = "\(b.name) (\(m))" }
            let n = (used[name] ?? 0) + 1; used[name] = n
            parts.append(ImportedPart(name: n > 1 ? "\(name) \(n)" : name, mesh: mesh, material: spec))
        }
        return parts
    }

    private static func parseMTL(_ data: Data) -> [String: MTL] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }
        var out: [String: MTL] = [:]
        var name: String?
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = fields.first else { continue }
            switch key {
            case "newmtl":
                name = fields.dropFirst().joined(separator: " ")
                if let name { out[name] = MTL() }
            case "Kd" where fields.count >= 4:
                if let name { out[name]?.color = SIMD4(Double(fields[1]) ?? 0.8, Double(fields[2]) ?? 0.8, Double(fields[3]) ?? 0.8, 1) }
            case "d" where fields.count >= 2:
                if let name, let d = Double(fields[1]) { out[name]?.color.w = d }
            case "map_Kd":
                // The file name is the last field; options (-s, -o …) precede it.
                if let name, let file = fields.last, fields.count >= 2 { out[name]?.texture = file }
            default:
                continue
            }
        }
        return out
    }
}

// MARK: - USD / USDZ through Model I/O

nonisolated enum USDImporter {
    /// USD's `metersPerUnit` (default 0.01 = centimetres) → millimetres.
    static func unitScale(of data: Data, ext: String) -> Double {
        var metersPerUnit = 0.01
        // A text layer (or a text layer inside the archive) states it plainly.
        let haystack: String? = ext == "usda"
            ? String(data: data, encoding: .utf8)
            : (try? ZipReader.entries(in: data))?.first { ($0.key as NSString).pathExtension == "usda" }
                .flatMap { String(data: $0.value, encoding: .utf8) }
        if let haystack, let range = haystack.range(of: "metersPerUnit") {
            let tail = haystack[range.upperBound...].prefix(40)
            let digits = tail.drop { !($0.isNumber || $0 == ".") }.prefix { $0.isNumber || $0 == "." || $0 == "e" || $0 == "-" }
            if let v = Double(digits), v > 0 { metersPerUnit = v }
        }
        return metersPerUnit * 1000
    }

    static func parts(from data: Data, fileName: String, unitScale: Double) throws -> [ImportedPart] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.\(ext.isEmpty ? "usdz" : ext)")
        try data.write(to: url)
        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            throw MeshImportError.unsupportedFormat(url.pathExtension)
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        guard let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh], !meshes.isEmpty else {
            throw MeshImportError.empty
        }
        var parts: [ImportedPart] = []
        for mesh in meshes {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            guard let positionData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                  let normalData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            else { continue }
            let texcoordData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2)
            let count = mesh.vertexCount
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let m3 = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                   SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                   SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
            let nm = m3.inverse.transpose
            var positions = [SIMD3<Float>](); positions.reserveCapacity(count)
            var normals = [SIMD3<Float>](); normals.reserveCapacity(count)
            var texcoords: [SIMD2<Float>]? = texcoordData == nil ? nil : []
            for i in 0..<count {
                let p = positionData.dataStart.advanced(by: i * positionData.stride).assumingMemoryBound(to: Float.self)
                let n = normalData.dataStart.advanced(by: i * normalData.stride).assumingMemoryBound(to: Float.self)
                let wp = world * SIMD4(p[0], p[1], p[2], 1)
                positions.append(SIMD3(wp.x, wp.y, wp.z) * Float(unitScale))
                let wn = nm * SIMD3(n[0], n[1], n[2])
                normals.append(simd_length(wn) > 1e-12 ? simd_normalize(wn) : SIMD3(0, 1, 0))
                if let t = texcoordData {
                    let uv = t.dataStart.advanced(by: i * t.stride).assumingMemoryBound(to: Float.self)
                    texcoords?.append(SIMD2(uv[0], 1 - uv[1]))   // USD's st origin is bottom-left
                }
            }
            for (si, sub) in ((mesh.submeshes as? [MDLSubmesh]) ?? []).enumerated() {
                guard sub.geometryType == .triangles || sub.geometryType == .quads else { continue }
                let map = sub.indexBuffer.map()
                var raw = [UInt32](); raw.reserveCapacity(sub.indexCount)
                for i in 0..<sub.indexCount {
                    switch sub.indexType {
                    case .uInt8: raw.append(UInt32(map.bytes.load(fromByteOffset: i, as: UInt8.self)))
                    case .uInt16: raw.append(UInt32(map.bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                    default: raw.append(map.bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    }
                }
                var indices: [UInt32] = []
                if sub.geometryType == .quads {
                    for q in stride(from: 0, to: raw.count - 3, by: 4) {
                        indices += [raw[q], raw[q + 1], raw[q + 2], raw[q], raw[q + 2], raw[q + 3]]
                    }
                } else {
                    indices = Array(raw.prefix(raw.count - raw.count % 3))
                }
                guard indices.count >= 3, indices.allSatisfy({ Int($0) < count }) else { continue }
                if m3.determinant < 0 {
                    for t in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(t + 1, t + 2) }
                }
                var render = RenderMesh(positions: positions, normals: normals, indices: indices)
                render.texcoords = texcoords
                var spec: BodyMaterialSpec?
                if let material = sub.material {
                    spec = BodyMaterialSpec(baseColor: SIMD4(0.8, 0.8, 0.8, 1), metallic: 0, roughness: 0.5)
                    if let base = material.property(with: .baseColor) {
                        switch base.type {
                        case .float3: spec?.baseColor = SIMD4(Double(base.float3Value.x), Double(base.float3Value.y), Double(base.float3Value.z), 1)
                        case .float4: spec?.baseColor = SIMD4(Double(base.float4Value.x), Double(base.float4Value.y), Double(base.float4Value.z), Double(base.float4Value.w))
                        case .texture:
                            if let texture = base.textureSamplerValue?.texture,
                               let image = texture.imageFromTexture()?.takeUnretainedValue(),
                               let png = MeshImportKit.pngData(image) {
                                spec?.baseColorTexture = png
                            }
                        default: break
                        }
                    }
                    if let m = material.property(with: .metallic), m.type == .float { spec?.metallic = Double(m.floatValue) }
                    if let r = material.property(with: .roughness), r.type == .float { spec?.roughness = Double(r.floatValue) }
                }
                if render.texcoords == nil { spec?.baseColorTexture = nil }
                let base = mesh.name.isEmpty ? "Part" : mesh.name
                let name = (mesh.submeshes?.count ?? 1) > 1 ? "\(base) \(si + 1)" : base
                parts.append(ImportedPart(name: name, mesh: render, material: spec))
            }
        }
        guard !parts.isEmpty else { throw MeshImportError.empty }
        return parts
    }
}

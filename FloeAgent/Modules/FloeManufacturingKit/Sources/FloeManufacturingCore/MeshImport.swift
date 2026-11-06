// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bounded local mesh input. Scale is explicit at this boundary; mesh coordinates
/// and the source identity are preserved in the manufacturing study thereafter.
public enum ManufacturingMeshImport {
    public struct Imported: Sendable {
        public var mesh: ManufacturingCAM.Mesh
        public var contentSHA256: String
        public var scaleToMM: Double
    }
    public static func read(_ data:Data,extension fileExtension:String,scaleToMM:Double = 1) throws -> Imported {
        guard !data.isEmpty, data.count <= 32_000_000, scaleToMM.isFinite, scaleToMM > 0, scaleToMM <= 1000 else { throw ManufacturingError.invalid("mesh input size or unit scale") }
        var builder = Builder(scale:scaleToMM)
        switch fileExtension.lowercased() {
        case "stl":
            if data.count >= 84 {
                let count = Int(u32(data,80))
                if count <= 180_000, data.count == 84+count*50 {
                    for i in 0..<count {
                        var triangle = [[Double]]()
                        for vertex in 0..<3 {
                            triangle.append((0..<3).map { Double(Float(bitPattern:u32(data,84+i*50+12+vertex*12+$0*4))) })
                        }
                        try builder.add(triangle)
                    }
                } else { try asciiSTL(data,into:&builder) }
            } else { try asciiSTL(data,into:&builder) }
        case "obj": try obj(data,into:&builder)
        default: throw ManufacturingError.invalid("supported reference meshes: triangle STL or OBJ")
        }
        let mesh = ManufacturingCAM.Mesh(vertices:builder.vertices,triangles:builder.triangles)
        try mesh.validate()
        return .init(mesh:mesh,contentSHA256:ManufacturingStudy.digest(data),scaleToMM:scaleToMM)
    }
    private static func u32(_ data:Data,_ offset:Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset+$1]) << ($1*8)) }
    }
    private static func asciiSTL(_ data:Data,into builder:inout Builder) throws {
        guard let text = String(data:data,encoding:.utf8), text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().hasPrefix("solid") else { throw ManufacturingError.invalid("malformed STL header/length") }
        var facet = false, loop = false, triangle = [[Double]]()
        for line in text.split(whereSeparator:\.isNewline) {
            let tokens = line.split(whereSeparator:\.isWhitespace)
            guard let first = tokens.first?.lowercased() else { continue }
            switch first {
            case "solid","endsolid": break
            case "facet":
                guard !facet && tokens.count == 5 && tokens[1].lowercased() == "normal" else { throw ManufacturingError.invalid("STL facet") }
                facet = true; triangle = []
            case "outer":
                guard facet && !loop && tokens.count == 2 && tokens[1].lowercased() == "loop" else { throw ManufacturingError.invalid("STL outer loop") }
                loop = true
            case "vertex":
                guard facet && loop && triangle.count < 3 && tokens.count == 4 else { throw ManufacturingError.invalid("STL vertex") }
                triangle.append(try numbers(tokens.dropFirst()))
            case "endloop":
                guard loop && triangle.count == 3 else { throw ManufacturingError.invalid("STL triangle requires three vertices") }; loop = false
            case "endfacet":
                guard facet && !loop && triangle.count == 3 else { throw ManufacturingError.invalid("STL incomplete facet") }
                try builder.add(triangle); facet = false
            default: throw ManufacturingError.invalid("unsupported STL record")
            }
        }
        guard !facet && !loop else { throw ManufacturingError.invalid("truncated STL") }
    }
    private static func obj(_ data:Data,into builder:inout Builder) throws {
        guard let text = String(data:data,encoding:.utf8) else { throw ManufacturingError.invalid("OBJ encoding") }
        var input = [[Double]]()
        for line in text.split(whereSeparator:\.isNewline) {
            let tokens = line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator:\.isWhitespace)
            guard let record = tokens.first else { continue }
            if record == "v" {
                guard tokens.count == 4, input.count < 120_000 else { throw ManufacturingError.invalid("OBJ vertex dimension/budget") }
                input.append(try numbers(tokens.dropFirst()))
            } else if record == "f" {
                guard tokens.count == 4 else { throw ManufacturingError.invalid("OBJ requires triangulated faces") }
                let triangle = try tokens.dropFirst().map { token -> [Double] in
                    guard let raw = token.split(separator:"/",omittingEmptySubsequences:false).first, let index = Int(raw), index != 0 else { throw ManufacturingError.invalid("OBJ face index") }
                    let position = index > 0 ? index-1 : input.count+index
                    guard input.indices.contains(position) else { throw ManufacturingError.invalid("OBJ face index out of range") }
                    return input[position]
                }
                try builder.add(triangle)
            } else if !["vt","vn","o","g","s","mtllib","usemtl"].contains(String(record)) { throw ManufacturingError.invalid("unsupported OBJ geometry record") }
        }
    }
    private static func numbers<S:Sequence>(_ tokens:S) throws -> [Double] where S.Element == Substring {
        try tokens.map { guard let value = Double($0), value.isFinite else { throw ManufacturingError.invalid("mesh coordinate") }; return value }
    }
    private struct Key: Hashable { var x:Double; var y:Double; var z:Double }
    private struct Builder {
        let scale:Double
        var vertices = [[Double]](), triangles = [[Int]](), indices = [Key:Int]()
        mutating func add(_ triangle:[[Double]]) throws {
            guard triangle.count == 3 && triangles.count < 180_000 else { throw ManufacturingError.invalid("mesh triangle budget") }
            let ids = try triangle.map { raw -> Int in
                let p = raw.map { $0*scale }
                guard CAMCheck.point(p) else { throw ManufacturingError.invalid("mesh coordinates after unit conversion") }
                let key = Key(x:p[0],y:p[1],z:p[2])
                if let existing = indices[key] { return existing }
                guard vertices.count < 120_000 else { throw ManufacturingError.invalid("mesh vertex budget") }
                let index = vertices.count; vertices.append(p); indices[key] = index; return index
            }
            triangles.append(ids)
        }
    }
}

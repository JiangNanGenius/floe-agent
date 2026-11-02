//
//  BlendImporter.swift
//  openshape3d
//
//  Reads Blender's own .blend files without Blender. A .blend is a list of
//  memory blocks dumped from the running program, described by the DNA1
//  block (struct names, field names, sizes) written alongside them — so
//  the reader parses that catalogue first and then reads every field by
//  name at the offset the catalogue gives, which is what makes one reader
//  work across versions. Supported: uncompressed and gzip files, 32/64-bit,
//  both endiannesses; mesh objects with MVert/MPoly/MLoop (2.63 … 3.4)
//  or the attribute layers that replaced them (3.5+); UVs from `mloopuv`,
//  a CD_MLOOPUV or a CD_PROP_FLOAT2 layer; materials by slot (viewport
//  colour) with a base-colour image from a 2.7x texture slot or a 2.8+
//  Image Texture node, packed in the file or beside it. Blender is Z-up
//  and metres; parts come out Y-up in millimetres.
//

import Compression
import Foundation
import simd

nonisolated enum BlendImporter {

    // MARK: - Entry

    static func parts(from raw: Data, siblings: [String: Data], unitScale: Double,
                      budget: MeshImportBudget = MeshImportBudget.fresh(fileName: "blend")) throws -> [ImportedPart] {
        var data = raw
        if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            data = try gunzip(data, budget: budget)
        } else if data.count >= 4, data[data.startIndex] == 0x28, data[data.startIndex + 1] == 0xb5,
                  data[data.startIndex + 2] == 0x2f, data[data.startIndex + 3] == 0xfd {
            throw MeshImportError.malformed("blend: this file is zstd-compressed (Blender 3.0+ \"Compress\" save); "
                                            + "save it without compression or export glTF")
        }
        // `BlendFile` keeps one byte array of the decoded file; charge the
        // copy before it is made so the gzip payload is never resident twice
        // beyond the same budget.
        try budget.charge(data.count, "blend decoded bytes")
        let file = try BlendFile(data, budget: budget)
        return try extract(file, siblings: siblings, unitScale: unitScale, budget: budget)
    }

    // MARK: - gzip

    private static func gunzip(_ data: Data, budget: MeshImportBudget) throws -> Data {
        // RFC 1952 header: ID1 ID2 CM FLG MTIME(4) XFL OS, then optional
        // fields by FLG; the payload is a raw deflate stream.
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[2] == 8 else { throw MeshImportError.malformed("blend: bad gzip header") }
        let flags = bytes[3]
        var p = 10
        if flags & 0x04 != 0 { let xlen = Int(bytes[p]) | Int(bytes[p + 1]) << 8; p += 2 + xlen }
        if flags & 0x08 != 0 { while p < bytes.count, bytes[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x10 != 0 { while p < bytes.count, bytes[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x02 != 0 { p += 2 }
        guard p < bytes.count - 8 else { throw MeshImportError.malformed("blend: truncated gzip") }
        // ISIZE (mod 2^32) in the trailer gives the size for anything under 4 GB.
        let isize = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        // The trailer is file-declared. Refuse an oversized ISIZE before the
        // destination buffer exists (a 10-byte gzip can claim 4 GiB).
        try budget.charge(isize, "blend gzip payload")
        guard isize <= budget.limits.maximumExpandedBytes else {
            throw MeshImportError.overBudget(
                "the Blender gzip payload declares \(isize / (1024 * 1024)) MiB, over the "
                + "\(budget.limits.maximumExpandedBytes / (1024 * 1024)) MiB import budget")
        }
        let capacity = max(isize, 1 << 16)
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress! + p, bytes.count - p - 8,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { throw MeshImportError.malformed("blend: gzip inflate failed") }
        out.count = produced
        return out
    }

    // MARK: - File structure

    struct Block {
        let code: String          // "OB", "ME", "MA", "IM", "DATA", …
        let size: Int
        let oldAddress: UInt64    // the pointer value other blocks use to reach this one
        let sdnaIndex: Int
        let count: Int
        let dataOffset: Int
    }

    struct Field {
        let typeName: String
        let name: String          // as written: "*mvert", "co[3]", "obmat[4][4]"
        let offset: Int
        let size: Int
        var isPointer: Bool { name.hasPrefix("*") || name.hasPrefix("(*") }
        var arrayCount: Int {
            var n = 1, s = Substring(name)
            while let a = s.firstIndex(of: "["), let b = s.firstIndex(of: "]"), a < b {
                n *= Int(s[s.index(after: a)..<b]) ?? 1
                s = s[s.index(after: b)...]
            }
            return n
        }
        var baseName: String {
            var s = name
            while s.hasPrefix("*") { s.removeFirst() }
            if s.hasPrefix("(") { s.removeFirst() }
            if let b = s.firstIndex(of: "[") { s = String(s[..<b]) }
            if let b = s.firstIndex(of: ")") { s = String(s[..<b]) }
            return s
        }
    }

    struct StructDef {
        let name: String
        let size: Int
        let fields: [Field]
        var byName: [String: Field]
    }

    final class BlendFile {
        let bytes: [UInt8]
        let pointerSize: Int
        let littleEndian: Bool
        let version: Int
        var blocks: [Block] = []
        var byAddress: [UInt64: Block] = [:]
        var structs: [StructDef] = []
        var structIndex: [String: Int] = [:]
        var typeSizes: [String: Int] = [:]

        init(_ data: Data, budget: MeshImportBudget) throws {
            bytes = [UInt8](data)
            guard bytes.count > 12, String(decoding: bytes[0..<7], as: UTF8.self) == "BLENDER" else {
                throw MeshImportError.malformed("blend: not a Blender file")
            }
            pointerSize = bytes[7] == UInt8(ascii: "-") ? 8 : 4
            littleEndian = bytes[8] == UInt8(ascii: "v")
            version = Int(String(decoding: bytes[9..<12], as: UTF8.self)) ?? 0
            try readBlocks(budget: budget)
            try readDNA()
        }

        // Scalars at absolute offsets, honouring the file's endianness.
        func u8(_ at: Int) -> UInt8 { at < bytes.count ? bytes[at] : 0 }
        func u16(_ at: Int) -> UInt16 {
            guard at + 2 <= bytes.count else { return 0 }
            let a = UInt16(bytes[at]), b = UInt16(bytes[at + 1])
            return littleEndian ? a | b << 8 : b | a << 8
        }
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
        func u32(_ at: Int) -> UInt32 {
            guard at + 4 <= bytes.count else { return 0 }
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(bytes[at + k]) << (littleEndian ? 8 * k : 8 * (3 - k)) }
            return v
        }
        func i32(_ at: Int) -> Int32 { Int32(bitPattern: u32(at)) }
        func u64(_ at: Int) -> UInt64 {
            guard at + 8 <= bytes.count else { return 0 }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(bytes[at + k]) << (littleEndian ? 8 * k : 8 * (7 - k)) }
            return v
        }
        func f32(_ at: Int) -> Float { Float(bitPattern: u32(at)) }
        func pointer(_ at: Int) -> UInt64 { pointerSize == 8 ? u64(at) : UInt64(u32(at)) }
        func cString(_ at: Int, max: Int) -> String {
            var end = at
            while end < min(at + max, bytes.count), bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }

        private func readBlocks(budget: MeshImportBudget) throws {
            var offset = 12
            let header = 16 + pointerSize
            while offset + header <= bytes.count {
                try budget.checkCancellation()
                let code = String(decoding: bytes[offset..<offset + 4].prefix { $0 != 0 }, as: UTF8.self)
                let size = Int(i32(offset + 4))
                let old = pointer(offset + 8)
                let sdna = Int(i32(offset + 8 + pointerSize))
                let count = Int(i32(offset + 12 + pointerSize))
                let block = Block(code: code, size: size, oldAddress: old, sdnaIndex: sdna, count: count,
                                  dataOffset: offset + header)
                blocks.append(block)
                if code == "ENDB" { break }
                guard size >= 0, block.dataOffset + size <= bytes.count else {
                    throw MeshImportError.malformed("blend: truncated block \(code)")
                }
                if byAddress[old] == nil { byAddress[old] = block }
                offset = block.dataOffset + size
            }
        }

        private func readDNA() throws {
            guard let dna = blocks.first(where: { $0.code == "DNA1" }) else {
                throw MeshImportError.malformed("blend: no DNA1 block")
            }
            var p = dna.dataOffset
            func expect(_ tag: String) throws {
                guard String(decoding: bytes[p..<p + 4], as: UTF8.self) == tag else {
                    throw MeshImportError.malformed("blend: DNA missing \(tag)")
                }
                p += 4
            }
            // Padding inside the DNA block is relative to the block's own
            // start, which need not be 4-aligned in the file.
            func align4() { p = dna.dataOffset + ((p - dna.dataOffset + 3) & ~3) }
            func readStrings() -> [String] {
                let n = Int(i32(p)); p += 4
                var out: [String] = []; out.reserveCapacity(n)
                for _ in 0..<n {
                    var end = p
                    while end < bytes.count, bytes[end] != 0 { end += 1 }
                    out.append(String(decoding: bytes[p..<end], as: UTF8.self)); p = end + 1
                }
                return out
            }
            try expect("SDNA")
            try expect("NAME"); let names = readStrings(); align4()
            try expect("TYPE"); let types = readStrings(); align4()
            try expect("TLEN")
            var lengths: [Int] = []
            for _ in types.indices { lengths.append(Int(i16(p))); p += 2 }
            align4()
            try expect("STRC")
            let structCount = Int(i32(p)); p += 4
            for (t, name) in types.enumerated() { typeSizes[name] = lengths[t] }
            for _ in 0..<structCount {
                let typeIndex = Int(i16(p)), fieldCount = Int(i16(p + 2)); p += 4
                var fields: [Field] = []
                var offset = 0
                for _ in 0..<fieldCount {
                    let ft = Int(i16(p)), fn = Int(i16(p + 2)); p += 4
                    let typeName = types[ft], fieldName = names[fn]
                    let field0 = Field(typeName: typeName, name: fieldName, offset: offset, size: 0)
                    let unit = field0.isPointer ? pointerSize : lengths[ft]
                    let size = unit * field0.arrayCount
                    fields.append(Field(typeName: typeName, name: fieldName, offset: offset, size: size))
                    offset += size
                }
                var byName: [String: Field] = [:]
                for f in fields { byName[f.baseName] = f }
                structIndex[types[typeIndex]] = structs.count
                structs.append(StructDef(name: types[typeIndex], size: lengths[typeIndex], fields: fields, byName: byName))
            }
        }

        // MARK: Field access

        func structDef(_ name: String) -> StructDef? { structIndex[name].map { structs[$0] } }
        func structName(of block: Block) -> String {
            block.sdnaIndex < structs.count ? structs[block.sdnaIndex].name : "?"
        }
        /// Absolute offset of `field` in the `index`-th struct of `block`.
        func fieldOffset(_ block: Block, _ structName: String, _ field: String, index: Int = 0) -> Int? {
            guard let def = structDef(structName), let f = def.byName[field] else { return nil }
            return block.dataOffset + index * def.size + f.offset
        }
        func int(_ block: Block, _ s: String, _ field: String, index: Int = 0) -> Int? {
            guard let def = structDef(s), let f = def.byName[field],
                  let at = fieldOffset(block, s, field, index: index) else { return nil }
            switch f.typeName {
            case "short": return Int(i16(at))
            case "ushort": return Int(u16(at))
            case "char": return Int(Int8(bitPattern: u8(at)))
            case "uchar": return Int(u8(at))
            case "int64_t": return Int(Int64(bitPattern: u64(at)))
            case "uint64_t": return Int(u64(at))
            default: return Int(i32(at))
            }
        }
        func ptr(_ block: Block, _ s: String, _ field: String, index: Int = 0) -> UInt64? {
            fieldOffset(block, s, field, index: index).map { pointer($0) }
        }
        func floats(_ block: Block, _ s: String, _ field: String, index: Int = 0) -> [Float]? {
            guard let def = structDef(s), let f = def.byName[field],
                  let at = fieldOffset(block, s, field, index: index) else { return nil }
            return (0..<f.arrayCount).map { f32(at + 4 * $0) }
        }
        func string(_ block: Block, _ s: String, _ field: String, index: Int = 0) -> String? {
            guard let def = structDef(s), let f = def.byName[field],
                  let at = fieldOffset(block, s, field, index: index) else { return nil }
            return cString(at, max: f.arrayCount)
        }
        /// The ID name with its two-letter type prefix stripped ("OBCube" → "Cube").
        func idName(_ block: Block, _ s: String) -> String {
            guard let def = structDef(s), let idField = def.byName["id"], let idDef = structDef("ID"),
                  let nameField = idDef.byName["name"] else { return "" }
            let raw = cString(block.dataOffset + idField.offset + nameField.offset, max: nameField.arrayCount)
            return raw.count > 2 ? String(raw.dropFirst(2)) : raw
        }
        func deref(_ address: UInt64?) -> Block? {
            guard let address, address != 0 else { return nil }
            return byAddress[address]
        }
        /// Pointers stored in a pointer-array block (e.g. Mesh.mat → Material**).
        func pointerArray(_ block: Block, count: Int) -> [UInt64] {
            (0..<max(count, 0)).compactMap { i in
                let at = block.dataOffset + i * pointerSize
                return at + pointerSize <= block.dataOffset + block.size ? pointer(at) : nil
            }
        }
        /// Custom-data layers of a CustomData embedded in `block` at `field`.
        func layers(_ block: Block, _ s: String, _ field: String) -> [(type: Int, name: String, data: Block?)] {
            guard let def = structDef(s), let f = def.byName[field], let cd = structDef("CustomData"),
                  let layersField = cd.byName["layers"], let totField = cd.byName["totlayer"] else { return [] }
            let base = block.dataOffset + f.offset
            let total = Int(i32(base + totField.offset))
            guard let layerBlock = deref(pointer(base + layersField.offset)) else { return [] }
            return (0..<max(total, 0)).map { i in
                (int(layerBlock, "CustomDataLayer", "type", index: i) ?? -1,
                 string(layerBlock, "CustomDataLayer", "name", index: i) ?? "",
                 deref(ptr(layerBlock, "CustomDataLayer", "data", index: i)))
            }
        }
    }

    // MARK: - Extraction

    private static let objectTypeMesh = 1
    private static let cdMLoopUV = 16, cdPropFloat2 = 49, cdPropFloat3 = 48, cdPropInt32 = 11

    private struct RawMaterial {
        var name: String
        var color: SIMD4<Double>
        var texture: Data?
    }

    /// New Blender files persist TRS and parenting, while the evaluated world
    /// matrix lives only in runtime memory. Reconstruct stored static object
    /// transforms; never silently replace an unavailable placement by identity.
    private final class StoredWorldTransforms {
        let file: BlendFile
        let budget: MeshImportBudget
        var cache: [UInt64: simd_double4x4] = [:]
        var visiting: Set<UInt64> = []

        init(file: BlendFile, budget: MeshImportBudget) {
            self.file = file
            self.budget = budget
        }

        private func refused(_ reason: String) -> CADDocumentError {
            CADDocumentError(code: "unsupported_import_content",
                message: "Blender object placement cannot be retained: \(reason). Export a static glTF or apply the evaluated transforms in Blender. Nothing was imported; the source is unchanged.")
        }

        private func matrix(_ ob: Block, _ name: String) throws -> simd_double4x4? {
            guard let values = file.floats(ob, "Object", name) else { return nil }
            guard values.count == 16, values.allSatisfy(\.isFinite),
                  abs(values[3]) < 1e-6, abs(values[7]) < 1e-6,
                  abs(values[11]) < 1e-6, abs(values[15] - 1) < 1e-6 else {
                throw refused("invalid \(name) transform")
            }
            return simd_double4x4(columns: (
                SIMD4(Double(values[0]), Double(values[1]), Double(values[2]), Double(values[3])),
                SIMD4(Double(values[4]), Double(values[5]), Double(values[6]), Double(values[7])),
                SIMD4(Double(values[8]), Double(values[9]), Double(values[10]), Double(values[11])),
                SIMD4(Double(values[12]), Double(values[13]), Double(values[14]), Double(values[15]))))
        }

        private func vector(_ ob: Block, _ name: String, fallback: SIMD3<Double>? = nil) throws -> SIMD3<Double> {
            guard let values = file.floats(ob, "Object", name) else {
                if let fallback { return fallback }
                throw refused("missing \(name)")
            }
            guard values.count == 3, values.allSatisfy(\.isFinite) else { throw refused("invalid \(name)") }
            return SIMD3(Double(values[0]), Double(values[1]), Double(values[2]))
        }

        private func rotation(_ ob: Block, delta: Bool) throws -> simd_double4x4 {
            let mode = file.int(ob, "Object", "rotmode") ?? 1
            let prefix = delta ? "d" : ""
            if mode == 0 {
                guard let values = file.floats(ob, "Object", prefix + "quat"), values.count == 4,
                      values.allSatisfy(\.isFinite) else { throw refused("invalid quaternion") }
                let q = SIMD4(Double(values[1]), Double(values[2]), Double(values[3]), Double(values[0]))
                return simd_length_squared(q) > 1e-20
                    ? simd_double4x4(simd_quatd(vector: simd_normalize(q))) : matrix_identity_double4x4
            }
            if mode == -1 {
                let angle = Double(file.floats(ob, "Object", prefix + "rotAngle")?.first ?? 0)
                let axis = try vector(ob, prefix + "rotAxis", fallback: SIMD3(0, 1, 0))
                guard angle.isFinite else { throw refused("invalid axis angle") }
                if abs(angle) < 1e-14 { return matrix_identity_double4x4 }
                guard simd_length_squared(axis) > 1e-20 else { throw refused("zero rotation axis") }
                return simd_double4x4(simd_quatd(angle: angle, axis: simd_normalize(axis)))
            }
            let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
            guard (1...orders.count).contains(mode) else { throw refused("unknown Euler order") }
            let angles = try vector(ob, prefix + "rot", fallback: delta ? .zero : nil)
            var result = matrix_identity_double4x4
            for index in orders[mode - 1] {
                var axis = SIMD3<Double>.zero; axis[index] = 1
                result = simd_double4x4(simd_quatd(angle: angles[index], axis: axis)) * result
            }
            return result
        }

        func world(_ ob: Block) throws -> simd_double4x4 {
            try budget.checkCancellation()
            if let cached = cache[ob.oldAddress] { return cached }
            guard visiting.count < 128, visiting.insert(ob.oldAddress).inserted else {
                throw refused("cyclic or excessively deep object hierarchy")
            }
            defer { visiting.remove(ob.oldAddress) }
            let world: simd_double4x4
            if let baked = try matrix(ob, "obmat") {
                world = baked
            } else {
                if let at = file.fieldOffset(ob, "Object", "constraints"),
                   let first = file.structDef("ListBase")?.byName["first"], file.pointer(at + first.offset) != 0 {
                    throw refused("evaluated constraints are not stored as a world transform")
                }
                let location = try vector(ob, "loc") + vector(ob, "dloc", fallback: .zero)
                // Base scale persists under the historical size spelling;
                // dscale is the live delta scale. The separate dsize member
                // in current DNA is obsolete and may be all zeroes.
                let fields = file.structDef("Object")?.byName ?? [:]
                let scale = try vector(ob, fields["scale"] == nil ? "size" : "scale")
                    * vector(ob, "dscale", fallback: SIMD3(repeating: 1))
                var local = try rotation(ob, delta: true) * rotation(ob, delta: false)
                    * simd_double4x4(diagonal: SIMD4(scale, 1))
                local.columns.3 = SIMD4(location, 1)
                if let address = file.ptr(ob, "Object", "parent"), address != 0 {
                    guard let parent = file.deref(address), file.structName(of: parent) == "Object",
                          (file.int(ob, "Object", "partype") ?? 0) & 0xF == 0,
                          file.int(parent, "Object", "type") != 2,
                          let inverse = try matrix(ob, "parentinv") else {
                        throw refused("unavailable or evaluated parenting")
                    }
                    world = try self.world(parent) * inverse * local
                } else {
                    world = local
                }
            }
            guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { world[c][$0].isFinite } }) else {
                throw refused("non-finite world transform")
            }
            try budget.charge(MemoryLayout<simd_double4x4>.stride, "Blender object transforms")
            cache[ob.oldAddress] = world
            return world
        }
    }

    private static func extract(_ file: BlendFile, siblings: [String: Data], unitScale: Double,
                                budget: MeshImportBudget) throws -> [ImportedPart] {
        guard file.structDef("Object") != nil, file.structDef("Mesh") != nil else {
            throw MeshImportError.malformed("blend: no Object/Mesh structs in DNA")
        }
        var parts: [ImportedPart] = []
        var materialCache: [UInt64: RawMaterial] = [:]
        let transforms = StoredWorldTransforms(file: file, budget: budget)

        for ob in file.blocks where ob.code == "OB" && file.structName(of: ob) == "Object" {
            try budget.checkCancellation()
            guard file.int(ob, "Object", "type") == objectTypeMesh else { continue }
            let name = file.idName(ob, "Object")
            guard let me = file.deref(file.ptr(ob, "Object", "data")), file.structName(of: me) == "Mesh" else {
                throw CADDocumentError(code: "missing_import_resources", message: "Blender mesh data is unavailable for object \(name). The whole import was refused; the source is unchanged.")
            }
            let world = try transforms.world(ob)
            let mirrored = simd_double3x3(
                SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)).determinant < 0

            guard let geometry = try geometry(of: me, in: file, budget: budget) else {
                throw CADDocumentError(code: "unsupported_import_content", message: "Unsupported Blender mesh layout for object \(name). The whole import was refused; the source is unchanged.")
            }
            let (positionsLocal, polygons, uvs) = geometry
            guard !polygons.isEmpty else { continue }

            // World, then Z-up → Y-up, then metres → mm.
            let positions: [SIMD3<Float>] = positionsLocal.map { p in
                let w = world * SIMD4(Double(p.x), Double(p.y), Double(p.z), 1)
                return SIMD3<Float>(Float(w.x * unitScale), Float(w.z * unitScale), Float(-w.y * unitScale))
            }

            // Materials by slot: the mesh's own list, else the object's.
            let totcol = file.int(me, "Mesh", "totcol") ?? 0
            var slotMaterials: [RawMaterial?] = []
            if totcol > 0, let matBlock = file.deref(file.ptr(me, "Mesh", "mat")) {
                for address in file.pointerArray(matBlock, count: totcol) {
                    if let cached = materialCache[address] { slotMaterials.append(cached); continue }
                    let raw = try file.deref(address).map { try material($0, in: file, siblings: siblings) }
                    if let raw { materialCache[address] = raw }
                    slotMaterials.append(raw)
                }
            }

            // One part per material slot actually used, like glTF primitives.
            var bySlot: [Int: [(Int, Int, Int)]] = [:]     // slot → corner triples (loop indices)
            for poly in polygons.polys {
                let loops = poly.loops
                guard loops.count >= 3 else { continue }
                for k in 1..<(loops.count - 1) {
                    bySlot[poly.materialSlot, default: []].append((loops[0], loops[k], loops[k + 1]))
                }
            }
            let usedSlots = bySlot.keys.sorted()
            for slot in usedSlots {
                let triangles = bySlot[slot]!
                // Split vertices by (vertex, uv) so a UV seam is a real seam.
                var indexOf: [Int64: UInt32] = [:]
                var outPositions: [SIMD3<Float>] = [], outUVs: [SIMD2<Float>] = [], outIndices: [UInt32] = []
                func corner(_ loop: Int) -> UInt32? {
                    guard loop < polygons.loopVertex.count else { return nil }
                    let v = polygons.loopVertex[loop]
                    guard v < positions.count else { return nil }
                    let uv = uvs.map { $0[loop] }
                    let key: Int64
                    if let uv {
                        // Quantise the UV to a hashable key: 1e-5 is finer than any texel.
                        key = Int64(v) << 40 ^ Int64(Int32((uv.x * 1e5).rounded())) << 20 ^ Int64(Int32((uv.y * 1e5).rounded())) & 0xFFFFF
                    } else {
                        key = Int64(v)
                    }
                    if let existing = indexOf[key] { return existing }
                    let idx = UInt32(outPositions.count)
                    indexOf[key] = idx
                    outPositions.append(positions[v])
                    if let uv { outUVs.append(SIMD2(uv.x, 1 - uv.y)) }   // Blender's UV origin is bottom-left
                    return idx
                }
                for (a, b, c) in triangles {
                    try budget.addTriangles(1)
                    guard let ia = corner(a), let ib = corner(b), let ic = corner(c) else { continue }
                    if mirrored { outIndices += [ia, ic, ib] } else { outIndices += [ia, ib, ic] }
                }
                guard outIndices.count >= 3 else { continue }
                var mesh = RenderMesh(positions: outPositions,
                                      normals: MeshImportKit.computedNormals(positions: outPositions, indices: outIndices),
                                      indices: outIndices)
                if uvs != nil, outUVs.count == outPositions.count { mesh.texcoords = outUVs }
                var spec: BodyMaterialSpec?
                if slot >= 0, slot < slotMaterials.count, let raw = slotMaterials[slot] {
                    spec = BodyMaterialSpec(baseColor: raw.color, metallic: 0, roughness: 0.5)
                    if let texture = raw.texture {
                        guard mesh.texcoords != nil else {
                            throw CADDocumentError(code: "unsupported_import_content", message: "Blender material \(raw.name) has an image but object \(name) has no supported UV map.")
                        }
                        try budget.charge(texture.count, "blend texture")
                        spec?.baseColorTexture = texture
                    }
                }
                let partName = usedSlots.count > 1
                    ? "\(name) (\(slotMaterials.indices.contains(slot) ? (slotMaterials[slot]?.name ?? "slot \(slot + 1)") : "slot \(slot + 1)"))"
                    : name
                try budget.addPart(partName)
                parts.append(ImportedPart(name: partName, mesh: mesh, material: spec))
            }
        }
        guard !parts.isEmpty else { throw MeshImportError.empty }
        return parts
    }

    private struct Polygons {
        struct Poly { let loops: [Int]; let materialSlot: Int }
        var polys: [Poly] = []
        var loopVertex: [Int] = []
        var isEmpty: Bool { polys.isEmpty }
    }

    /// Vertex positions (local), polygons with their corner loops, and per-loop
    /// UVs if the mesh has any — from whichever storage the file's version uses.
    private static func geometry(of me: Block, in file: BlendFile,
                                 budget: MeshImportBudget) throws
        -> (positions: [SIMD3<Float>], polygons: Polygons, uvs: [SIMD2<Float>]?)? {
        let totvert = file.int(me, "Mesh", "totvert") ?? 0
        let totpoly = file.int(me, "Mesh", "totpoly") ?? 0
        let totloop = file.int(me, "Mesh", "totloop") ?? 0
        guard totvert > 0, totpoly > 0, totloop > 0 else { return nil }
        // Mesh counts are file-declared. Refuse a count the import budget
        // cannot hold BEFORE reserving or mapping that many elements.
        guard totvert <= budget.limits.maximumTriangles * 3,
              totloop <= budget.limits.maximumTriangles * 12,
              totpoly <= budget.limits.maximumTriangles else {
            throw MeshImportError.overBudget(
                "the Blender mesh declares \(totvert) vertices / \(totpoly) faces, over the import budget")
        }
        try budget.charge(totvert * MemoryLayout<SIMD3<Float>>.stride
                          + totloop * MemoryLayout<Int>.stride
                          + totpoly * 48,
                          "Blender mesh arrays")

        try budget.checkCancellation()
        // Positions: MVert.co (≤ 3.4) or the "position" float3 vertex layer (3.5+).
        var positions: [SIMD3<Float>] = []
        if let mv = file.deref(file.ptr(me, "Mesh", "mvert")), file.structDef("MVert")?.byName["co"] != nil {
            positions.reserveCapacity(totvert)
            for i in 0..<totvert {
                guard let co = file.floats(mv, "MVert", "co", index: i), co.count >= 3 else { break }
                positions.append(SIMD3(co[0], co[1], co[2]))
            }
        } else if let layer = file.layers(me, "Mesh", "vdata").first(where: { $0.type == cdPropFloat3 && $0.name == "position" }),
                  let data = layer.data {
            positions = (0..<totvert).map { i in
                SIMD3(file.f32(data.dataOffset + 12 * i), file.f32(data.dataOffset + 12 * i + 4), file.f32(data.dataOffset + 12 * i + 8))
            }
        }
        guard positions.count == totvert else { return nil }

        try budget.checkCancellation()
        // Corner → vertex: MLoop.v (≤ 3.5) or the ".corner_vert" int layer (3.6+).
        var loopVertex: [Int] = []
        if let ml = file.deref(file.ptr(me, "Mesh", "mloop")), file.structDef("MLoop")?.byName["v"] != nil {
            loopVertex = (0..<totloop).map { file.int(ml, "MLoop", "v", index: $0) ?? 0 }
        } else if let layer = file.layers(me, "Mesh", "ldata").first(where: { $0.type == cdPropInt32 && $0.name == ".corner_vert" }),
                  let data = layer.data {
            loopVertex = (0..<totloop).map { Int(file.i32(data.dataOffset + 4 * $0)) }
        }
        guard loopVertex.count == totloop else { return nil }

        // Polygons: MPoly (loopstart/totloop/mat_nr, ≤ 3.5) or poly_offset_indices
        // (3.6+) with the "material_index" int face layer.
        var polygons = Polygons()
        polygons.loopVertex = loopVertex
        if let mp = file.deref(file.ptr(me, "Mesh", "mpoly")), file.structDef("MPoly")?.byName["loopstart"] != nil {
            for i in 0..<totpoly {
                if i % 4096 == 0 { try budget.checkCancellation() }
                let start = file.int(mp, "MPoly", "loopstart", index: i) ?? 0
                let count = file.int(mp, "MPoly", "totloop", index: i) ?? 0
                let slot = file.int(mp, "MPoly", "mat_nr", index: i) ?? 0
                guard start >= 0, count >= 3, start + count <= totloop else { continue }
                polygons.polys.append(.init(loops: Array(start..<start + count), materialSlot: max(slot, 0)))
            }
        } else if let offsets = file.deref(file.ptr(me, "Mesh", "poly_offset_indices")) {
            let slots = file.layers(me, "Mesh", "pdata").first(where: { $0.type == cdPropInt32 && $0.name == "material_index" })?.data
            for i in 0..<totpoly {
                if i % 4096 == 0 { try budget.checkCancellation() }
                let start = Int(file.i32(offsets.dataOffset + 4 * i))
                let end = Int(file.i32(offsets.dataOffset + 4 * (i + 1)))
                let slot = slots.map { Int(file.i32($0.dataOffset + 4 * i)) } ?? 0
                guard start >= 0, end - start >= 3, end <= totloop else { continue }
                polygons.polys.append(.init(loops: Array(start..<end), materialSlot: max(slot, 0)))
            }
        }
        guard !polygons.isEmpty else { return nil }

        try budget.checkCancellation()
        // UVs per corner: Mesh.mloopuv, a CD_MLOOPUV layer, or a float2 layer.
        var uvs: [SIMD2<Float>]?
        if let muv = file.deref(file.ptr(me, "Mesh", "mloopuv")), file.structDef("MLoopUV")?.byName["uv"] != nil {
            uvs = (0..<totloop).map { i in
                let uv = file.floats(muv, "MLoopUV", "uv", index: i) ?? [0, 0]
                return SIMD2(uv[0], uv.count > 1 ? uv[1] : 0)
            }
        } else {
            let layers = file.layers(me, "Mesh", "ldata")
            if let layer = layers.first(where: { $0.type == cdMLoopUV }), let data = layer.data,
               let stride = file.structDef("MLoopUV")?.size, stride >= 8 {
                uvs = (0..<totloop).map { SIMD2(file.f32(data.dataOffset + stride * $0), file.f32(data.dataOffset + stride * $0 + 4)) }
            } else if let layer = layers.first(where: { $0.type == cdPropFloat2 && !$0.name.hasPrefix(".") }), let data = layer.data {
                uvs = (0..<totloop).map { SIMD2(file.f32(data.dataOffset + 8 * $0), file.f32(data.dataOffset + 8 * $0 + 4)) }
            }
        }
        return (positions, polygons, uvs)
    }

    /// Slot colour and base-colour image for a Material block.
    private static func material(_ ma: Block, in file: BlendFile, siblings: [String: Data]) throws -> RawMaterial {
        let name = file.idName(ma, "Material")
        let r = Double(file.floats(ma, "Material", "r")?.first ?? 0.8)
        let g = Double(file.floats(ma, "Material", "g")?.first ?? 0.8)
        let b = Double(file.floats(ma, "Material", "b")?.first ?? 0.8)
        let alpha = Double(file.floats(ma, "Material", "alpha")?.first ?? 1)
        var raw = RawMaterial(name: name, color: SIMD4(r, g, b, alpha > 0 ? alpha : 1), texture: nil)

        var image: Block?
        // 2.7x: texture slots — the first colour-mapped image texture.
        if let mtexField = file.structDef("Material")?.byName["mtex"], mtexField.isPointer {
            let base = ma.dataOffset + mtexField.offset
            for i in 0..<mtexField.arrayCount where image == nil {
                guard let mtex = file.deref(file.pointer(base + i * file.pointerSize)),
                      let tex = file.deref(file.ptr(mtex, "MTex", "tex")),
                      (file.int(mtex, "MTex", "mapto") ?? 1) & 1 != 0,
                      file.int(tex, "Tex", "type") == 8,                // TEX_IMAGE
                      let ima = file.deref(file.ptr(tex, "Tex", "ima")) else { continue }
                image = ima
            }
        }
        // 2.8+: the node tree's first Image Texture node.
        if image == nil, let tree = file.deref(file.ptr(ma, "Material", "nodetree")),
           let nodesField = file.structDef("bNodeTree")?.byName["nodes"], let listBase = file.structDef("ListBase"),
           let firstField = listBase.byName["first"], let nodeDef = file.structDef("bNode"),
           nodeDef.byName["next"] != nil {
            var node = file.deref(file.pointer(tree.dataOffset + nodesField.offset + firstField.offset))
            var guardCount = 0
            while let current = node, guardCount < 512, image == nil {
                guardCount += 1
                let idname = file.string(current, "bNode", "idname") ?? ""
                if idname == "ShaderNodeTexImage", let ima = file.deref(file.ptr(current, "bNode", "id")),
                   file.structName(of: ima) == "Image" {
                    image = ima
                }
                node = file.deref(file.ptr(current, "bNode", "next"))
            }
        }
        if let image {
            let bytes = try imageData(image, in: file, siblings: siblings)
            if case .failure = CADExportImage.decode(bytes) {
                throw CADDocumentError(code: "unsupported_import_content", message: "Unsupported or unreadable Blender image for material \(name). The source is unchanged.")
            }
            raw.texture = bytes
        }
        return raw
    }

    /// The image's bytes: packed inside the .blend, or a file that came along.
    private static func imageData(_ ima: Block, in file: BlendFile, siblings: [String: Data]) throws -> Data {
        if let packed = file.deref(file.ptr(ima, "Image", "packedfile")),
           let size = file.int(packed, "PackedFile", "size"), size > 0,
           let data = file.deref(file.ptr(packed, "PackedFile", "data")), data.size >= size {
            return Data(file.bytes[data.dataOffset..<data.dataOffset + size])
        }
        // 2.8+ keeps a list of packed files (tiles / views); take the first.
        if let listField = file.structDef("Image")?.byName["packedfiles"], let listBase = file.structDef("ListBase"),
           let firstField = listBase.byName["first"],
           let entry = file.deref(file.pointer(ima.dataOffset + listField.offset + firstField.offset)),
           let packed = file.deref(file.ptr(entry, "ImagePackedFile", "packedfile")),
           let size = file.int(packed, "PackedFile", "size"), size > 0,
           let data = file.deref(file.ptr(packed, "PackedFile", "data")), data.size >= size {
            return Data(file.bytes[data.dataOffset..<data.dataOffset + size])
        }
        let path = (file.string(ima, "Image", "filepath") ?? file.string(ima, "Image", "name") ?? "")
            .replacingOccurrences(of: "\\", with: "/")
        let trimmed = path.hasPrefix("//") ? String(path.dropFirst(2)) : path
        guard !trimmed.isEmpty else {
            throw CADDocumentError(code: "unsupported_import_content", message: "Blender image \(file.idName(ima, "Image")) has no supported packed bytes or resource path.")
        }
        guard let bytes = MeshImportKit.sibling(trimmed, in: siblings) else {
            throw CADDocumentError(code: "missing_import_resources", message: "Missing Blender image resource: \(trimmed). Select the image with the model; the source is unchanged.")
        }
        return bytes
    }
}

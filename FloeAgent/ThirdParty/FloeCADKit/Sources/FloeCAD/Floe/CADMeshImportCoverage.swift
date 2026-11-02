// SPDX-License-Identifier: MPL-2.0
// Import inspection consumes already-authorized bytes. A referenced name can
// never open a URL, read a sibling folder, fetch the network or grant access.
import Foundation
import CoreFoundation
import CryptoKit

public nonisolated enum CADImportUnits {
    /// Shared strict contract for direct commands and host import payloads.
    /// An invalid explicit value never falls back to detection or another field.
    public static func resolve(units: Any?, scale: Any?) throws -> Double? {
        var named:Double?, numeric:Double?
        if let raw=units {
            guard let text=raw as? String,let unit=MeshImportUnit.parse(text) else {
                throw CADDocumentError(code:"bad_units",message:"units must be mm, cm, m, in or ft.")
            }
            named=unit.millimetresPerUnit
        }
        if let raw=scale {
            guard let number=raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,number.doubleValue > 0 else {
                throw CADDocumentError(code:"bad_unit_scale",message:"unitScale must be a positive finite number.")
            }
            numeric=number.doubleValue
        }
        if let named,let numeric,abs(named-numeric) > max(named,numeric)*1e-12 {
            throw CADDocumentError(code:"conflicting_units",message:"units and unitScale describe different lengths; choose one consistent value.")
        }
        return numeric ?? named
    }
}

public nonisolated enum CADImportResources {
    /// Logical names only. Parent components remain valid aliases ONLY for
    /// explicitly supplied bytes; they are never resolved against a filesystem.
    public static func name(_ raw:String, relativeTo file:String = "") -> String? {
        let decoded=(raw.removingPercentEncoding ?? raw).replacingOccurrences(of:"\\",with:"/")
        let relative=decoded.hasPrefix("//") ? String(decoded.dropFirst(2)) : decoded
        guard relative.utf8.count <= 4096,!relative.isEmpty,!relative.hasPrefix("/"),!relative.contains(":"),!relative.contains("\0") else { return nil }
        let parent=(file as NSString).deletingLastPathComponent
        var parts:[String]=[]
        for part in (parent.isEmpty ? relative : parent+"/"+relative).split(separator:"/") {
            if part == "." { continue }
            if part == "..",let last=parts.last,last != ".." { parts.removeLast() }
            else { parts.append(String(part)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator:"/").lowercased()
    }
    public static func normalized(_ resources:[String:Data]) throws -> [String:Data] {
        var output:[String:Data]=[:]
        for (key,data) in resources {
            guard let clean=name(key),output[clean] == nil else {
                throw CADDocumentError(code:"ambiguous_import_resources",message:"Resource names are invalid or collide: \(key). Select an unambiguous file group.")
            }
            output[clean]=data
        }
        return output
    }
    static func rebased(_ resources:[String:Data], primary:String) throws -> [String:Data] {
        let normalized=try normalized(resources)
        let parent=(primary.replacingOccurrences(of:"\\",with:"/") as NSString).deletingLastPathComponent.lowercased()
        guard !parent.isEmpty else { return normalized }
        let root=parent.split(separator:"/").map(String.init)
        var result:[String:Data]=[:]
        for (key,bytes) in normalized {
            let path=key.split(separator:"/").map(String.init)
            var common=0
            while common < min(path.count,root.count),path[common] == root[common] { common += 1 }
            let relative=Array(repeating:"..",count:root.count-common)+Array(path.dropFirst(common))
            result[relative.joined(separator:"/")]=bytes
        }
        return result
    }
    public static func sha256(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func hashes(_ resources:[String:Data]) throws -> [String:String] {
        try normalized(resources).mapValues(sha256)
    }
}

public nonisolated struct CADMeshImportCoverage: Codable,Sendable,Equatable {
    public var fileName:String
    public var format:String
    public var sourceSHA256:String
    public var resourceSHA256:[String:String]
    public var retained:[String]
    public var discarded:[String]
    public var missingResources:[String]
    public var unsupported:[String]
    public var sourceRetained=true
    public var actualPartCount=0
    public var actualTriangleCount=0
    public var selectedScaleMM:Double?

    public var summary:String {
        "Static import; retained: \(retained.joined(separator:", ")). "
        + "Not retained: \(discarded.joined(separator:", ")). Original source files are unchanged."
    }
    public var json:[String:Any] {
        var result:[String:Any]=["file_name":fileName,"format":format,"source_sha256":sourceSHA256,
            "resource_sha256":resourceSHA256,"retained":retained,"discarded":discarded,
            "missing_resources":missingResources,"unsupported":unsupported,"source_retained":sourceRetained,
            "part_count":actualPartCount,"triangle_count":actualTriangleCount,"note":summary]
        if let selectedScaleMM { result["millimetres_per_unit"]=selectedScaleMM }
        return result
    }
    func requireCompleteResources() throws {
        if !missingResources.isEmpty {
            throw CADDocumentError(code:"missing_import_resources",message:"Missing import resources: \(missingResources.joined(separator:", ")). Select those files with the model or use one complete ZIP. Nothing was imported; the source files are unchanged.")
        }
        if !unsupported.isEmpty {
            throw CADDocumentError(code:"unsupported_import_content",message:"Cannot import this source completely: \(unsupported.joined(separator:"; ")). The source files are unchanged.")
        }
    }

    static func inspect(data:Data,fileName:String,resources:[String:Data]) throws -> Self {
        let ext=(fileName as NSString).pathExtension.lowercased()
        let siblings=try CADImportResources.normalized(resources)
        var report=Self(fileName:(fileName as NSString).lastPathComponent,format:ext,
            sourceSHA256:CADImportResources.sha256(data),resourceSHA256:try CADImportResources.hashes(siblings),
            retained:["static_mesh","object_placement"],discarded:["parametric_history"],missingResources:[],unsupported:[])
        func reference(_ raw:String,from base:String = "",image:Bool=false) {
            if raw.hasPrefix("data:") { return }
            guard let key=CADImportResources.name(raw,relativeTo:base) else {
                report.unsupported.append("External/absolute resource reference: \(raw)");return
            }
            guard let bytes=siblings[key] else { report.missingResources.append(key);return }
            if image,case .failure=CADExportImage.decode(bytes) {
                report.unsupported.append("Unreadable or unsupported texture: \(key)")
            }
        }
        switch ext {
        case "obj":
            report.retained += ["part_names","uv0","base_color"]
            report.discarded += ["material_channels_other_than_base_color"]
            let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) ?? ""
            var materialNames=Set<String>(),usedMaterials=Set<String>()
            for line in text.split(whereSeparator:{$0 == "\n" || $0 == "\r"}) {
                let fields=line.split(whereSeparator:{$0 == " " || $0 == "\t"}).map(String.init)
                if fields.first == "mtllib" {
                    for path in fields.dropFirst() {
                        reference(path)
                        guard let key=CADImportResources.name(path),let bytes=siblings[key] else { continue }
                        let mtl=String(data:bytes,encoding:.utf8) ?? String(data:bytes,encoding:.isoLatin1) ?? ""
                        for raw in mtl.split(whereSeparator:{$0 == "\n" || $0 == "\r"}) {
                            let row=raw.split(whereSeparator:{$0 == " " || $0 == "\t"}).map(String.init)
                            if row.first == "newmtl" { materialNames.insert(row.dropFirst().joined(separator:" ")) }
                            if row.first == "map_Kd",row.count >= 2 { reference(row.last!,from:key,image:true) }
                        }
                    }
                }
                if fields.first == "usemtl" { usedMaterials.insert(fields.dropFirst().joined(separator:" ")) }
            }
            for name in usedMaterials.subtracting(materialNames).sorted() { report.unsupported.append("Undefined OBJ material: \(name)") }
        case "gltf","glb":
            report.retained += ["part_names","uv0","supported_pbr_materials"]
            report.discarded += ["editable_scene_hierarchy"]
            let object=try gltfJSON(data,binary:ext == "glb")
            for key in ["buffers","images"] {
                for row in object[key] as? [[String:Any]] ?? [] {
                    if let uri=row["uri"] as? String { reference(uri,image:key == "images") }
                }
            }
            for key in ["animations","skins"] where !(object[key] as? [Any] ?? []).isEmpty { report.discarded.append(key) }
            if (object["accessors"] as? [[String:Any]] ?? []).contains(where:{$0["sparse"] != nil}) { report.unsupported.append("Sparse glTF accessors") }
            for ext in object["extensionsRequired"] as? [String] ?? [] where !["KHR_texture_transform","KHR_materials_pbrSpecularGlossiness","KHR_materials_emissive_strength"].contains(ext) { report.unsupported.append("Required glTF extension: \(ext)") }
            func inspectTransforms(_ value:Any) {
                if let object=value as? [String:Any] {
                    if let transform=object["KHR_texture_transform"] as? [String:Any] {
                        let scale=transform["scale"] as? [Double] ?? [1,1], offset=transform["offset"] as? [Double] ?? [0,0]
                        let rotation=(transform["rotation"] as? NSNumber)?.doubleValue ?? 0
                        let identity=scale == [1,1] && offset == [0,0]
                        let flip=scale == [1,-1] && offset == [0,1]
                        if !(rotation == 0 && (identity || flip)) { report.unsupported.append("General KHR_texture_transform mapping") }
                    }
                    for value in object.values { inspectTransforms(value) }
                } else if let array=value as? [Any] { for value in array { inspectTransforms(value) } }
            }
            inspectTransforms(object)
            for mesh in object["meshes"] as? [[String:Any]] ?? [] {
                for primitive in mesh["primitives"] as? [[String:Any]] ?? [] {
                    if primitive["targets"] != nil { report.discarded.append("morph_targets") }
                    if (primitive["mode"] as? Int ?? 4) != 4 { report.unsupported.append("glTF primitive mode \(primitive["mode"] ?? "unknown")") }
                }
            }
        case "blend":
            report.retained += ["part_names","uv0","base_color","base_color_texture"]
            report.discarded += ["material_channels_other_than_base_color","editable_scene_hierarchy","animation_rig_modifiers","unverified_scene_data"]
        case "usd","usda","usdc","usdz":
            report.retained += ["supported_static_materials"]
            report.discarded += ["editable_scene_hierarchy","animation_rig_modifiers","unverified_scene_data"]
            if ext != "usdz",ext != "blend",let text=String(data:data,encoding:.utf8),
               let regex=try? NSRegularExpression(pattern:"@([^@]+)@") {
                let value=text as NSString
                for match in regex.matches(in:text,range:NSRange(location:0,length:value.length)) {
                    let path=value.substring(with:match.range(at:1));reference(path,image:false)
                    report.unsupported.append("Loose USD external asset \(path); use a self-contained USDZ")
                }
            }
        default:break
        }
        report.discarded=Array(Set(report.discarded)).sorted()
        report.missingResources=Array(Set(report.missingResources)).sorted()
        report.unsupported=Array(Set(report.unsupported)).sorted()
        return report
    }

    /// Metadata inspection only, not a second geometry importer.
    private static func gltfJSON(_ data:Data,binary:Bool) throws -> [String:Any] {
        var bytes=data
        if binary {
            guard data.count >= 20 else { throw MeshImportError.malformed("glb: too short") }
            func u32(_ at:Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt32.self)) } }
            guard u32(0) == 0x46546c67,u32(16) == 0x4E4F534A,Int(u32(12)) <= data.count-20 else { throw MeshImportError.malformed("glb: missing JSON chunk") }
            bytes=data.subdata(in:20..<20+Int(u32(12)))
        }
        guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw MeshImportError.malformed("gltf: not a JSON object") }
        return object
    }
}

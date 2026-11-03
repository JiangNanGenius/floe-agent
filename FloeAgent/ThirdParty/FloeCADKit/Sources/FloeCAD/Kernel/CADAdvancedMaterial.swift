// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import simd

nonisolated struct CADMaterialJSONKey:CodingKey {
    var stringValue:String;var intValue:Int? { nil }
    init(stringValue:String) { self.stringValue=stringValue }
    init?(intValue:Int) { return nil }
}
nonisolated enum CADMaterialStrict {
    static func keys(_ decoder:Decoder,_ allowed:Set<String>) throws {
        let c=try decoder.container(keyedBy:CADMaterialJSONKey.self)
        guard Set(c.allKeys.map(\.stringValue)).isSubset(of:allowed) else { throw CADMaterialGraphError.invalid }
    }
}
/// Optional: nil preserves the historical material and its serialized shape.
nonisolated struct CADAdvancedMaterial:Codable,Equatable,Hashable,Sendable {
    var version=1
    var clearcoat:Double=0
    var coatRoughness:Double=0
    var anisotropyLevel:Double=0
    /// RealityKit's native scale. Apple does not document conversion to glTF
    /// radians; a nonzero value is explicitly reported as lossy on GLB export.
    var anisotropyAngle:Double=0
    var specular:Double=1
    var sheen:SIMD3<Double> = .zero
    private enum CodingKeys:String,CodingKey { case version,clearcoat,coatRoughness,anisotropyLevel,anisotropyAngle,specular,sheen }
    init() {}
    init(from decoder:Decoder) throws {
        try CADMaterialStrict.keys(decoder,["version","clearcoat","coatRoughness","anisotropyLevel","anisotropyAngle","specular","sheen"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        clearcoat=try c.decodeIfPresent(Double.self,forKey:.clearcoat) ?? 0;coatRoughness=try c.decodeIfPresent(Double.self,forKey:.coatRoughness) ?? 0
        anisotropyLevel=try c.decodeIfPresent(Double.self,forKey:.anisotropyLevel) ?? 0;anisotropyAngle=try c.decodeIfPresent(Double.self,forKey:.anisotropyAngle) ?? 0
        specular=try c.decodeIfPresent(Double.self,forKey:.specular) ?? 1;sheen=try c.decodeIfPresent(SIMD3<Double>.self,forKey:.sheen) ?? .zero
        try validate()
    }
    func validate() throws {
        guard version==1,[clearcoat,coatRoughness,anisotropyLevel,anisotropyAngle,specular,sheen.x,sheen.y,sheen.z].allSatisfy({$0.isFinite && (0...1).contains($0)}) else { throw CADMaterialGraphError.invalid }
    }
    var json:[String:Any] { ["version":version,"clearcoat":clearcoat,"coatRoughness":coatRoughness,"anisotropyLevel":anisotropyLevel,"anisotropyAngle":anisotropyAngle,"specular":specular,"sheen":[sheen.x,sheen.y,sheen.z]] }
    var exportNotes:[String] { anisotropyAngle==0 ? []:["anisotropy_angle_native_scale_not_converted_to_gltf_radians"] }
}

nonisolated enum CADMaterialAppearanceIntent {
    static func inspect(_ data:Data?) -> (present:Bool,opaque:Bool) {
        guard let data,let raw=try? JSONSerialization.jsonObject(with:data) else { return (false,false) }
        var present=false,opaque=false
        func walk(_ value:Any,_ depth:Int) {
            guard depth<24 else { opaque=true;return }
            if let row=value as? [String:Any] {
                if row["baseColor"] is [Any], row["roughness"] is NSNumber, row["metallic"] is NSNumber {
                    let body:Set<String>=["baseColor","metallic","roughness","baseColorTexture","materialID","materialName","opacity","emissive","emissiveStrength","roughnessTexture","metallicTexture","normalTexture","emissiveTexture","opacityTexture","uvMapping","textureMetadata","advanced","nodeGraph"]
                    let definition:Set<String>=["id","name","baseColor","metallic","roughness","opacity","emissive","emissiveStrength","textures","uvMapping","revision","createdAt","updatedAt","advanced","nodeGraph"]
                    if !Set(row.keys).isSubset(of:row["textures"] == nil ? body:definition) { present=true;opaque=true }
                }
                if let advanced=row["advanced"],!(advanced is NSNull) {
                    present=true
                    guard let bytes=try? JSONSerialization.data(withJSONObject:advanced),(try? JSONDecoder().decode(CADAdvancedMaterial.self,from:bytes)) != nil else { opaque=true;return }
                }
                if let graph=row["nodeGraph"],!(graph is NSNull) {
                    present=true
                    do {
                        let graph=try JSONDecoder().decode(CADMaterialNodeGraph.self,from:JSONSerialization.data(withJSONObject:graph));try graph.validate(requireBake:true)
                        if let textures=row["textures"] as? [[String:Any]] {
                            let decoded=try JSONDecoder().decode([CADMaterialTexture].self,from:JSONSerialization.data(withJSONObject:textures))
                            for (slot,sha) in graph.bakedSHA256 ?? [:] { guard decoded.first(where:{$0.slot.rawValue==slot})?.sha256==sha else { throw CADMaterialGraphError.invalid } }
                        } else {
                            for (slot,sha) in graph.bakedSHA256 ?? [:] {
                                let key:[String:String]=["baseColor":"baseColorTexture","roughness":"roughnessTexture","metallic":"metallicTexture"]
                                guard let field=key[slot],let encoded=row[field] as? String,let bytes=Data(base64Encoded:encoded),CADMaterialTexture.digest(bytes)==sha else { throw CADMaterialGraphError.invalid }
                            }
                        }
                    } catch { opaque=true }
                }
                for (key,child) in row where key != "nodeGraph" && key != "advanced" { walk(child,depth+1) }
            } else if let array=value as? [Any] { for child in array { walk(child,depth+1) } }
        }
        walk(raw,0);return (present,opaque)
    }
    static func readableLibrary(_ data:Data) -> Bool {
        guard data.count<=CADMaterialLimits.maximumLibraryBytes,let row=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(row.keys).isSubset(of:["schemaVersion","entries","updatedAt"]),let rawVersion=row["schemaVersion"] as? NSNumber,
              CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),rawVersion.doubleValue.isFinite,rawVersion.doubleValue.rounded()==rawVersion.doubleValue,(1...2).contains(rawVersion.doubleValue),
              let entries=row["entries"] as? [[String:Any]],entries.count<=CADMaterialLimits.maximumLibraryEntries,
              entries.allSatisfy({Set($0.keys).isSubset(of:["id","name","baseColor","metallic","roughness","opacity","emissive","emissiveStrength","textures","uvMapping","revision","createdAt","updatedAt","advanced","nodeGraph"])}) else { return false }
        let intent=inspect(data)
        return !intent.opaque && (!intent.present || rawVersion.intValue>=2)
    }
}

// Strict decoders are extensions so existing memberwise construction remains
// available. Future library/snapshot semantics can never sanitize to defaults.
nonisolated extension CADMaterialDefinition {
    private enum AdvancedKeys:String,CodingKey { case id,name,baseColor,metallic,roughness,opacity,emissive,emissiveStrength,textures,uvMapping,revision,createdAt,updatedAt,advanced,nodeGraph }
    init(from decoder:Decoder) throws {
        try CADMaterialStrict.keys(decoder,["id","name","baseColor","metallic","roughness","opacity","emissive","emissiveStrength","textures","uvMapping","revision","createdAt","updatedAt","advanced","nodeGraph"])
        let c=try decoder.container(keyedBy:AdvancedKeys.self)
        self.init(id:try c.decode(MaterialID.self,forKey:.id),name:try c.decode(String.self,forKey:.name),
            baseColor:try c.decode(SIMD4<Double>.self,forKey:.baseColor),metallic:try c.decode(Double.self,forKey:.metallic),roughness:try c.decode(Double.self,forKey:.roughness),
            opacity:try c.decode(Double.self,forKey:.opacity),emissive:try c.decode(SIMD3<Double>.self,forKey:.emissive),emissiveStrength:try c.decode(Double.self,forKey:.emissiveStrength),
            textures:try c.decode([CADMaterialTexture].self,forKey:.textures),uvMapping:try c.decode(CADMaterialUVMapping.self,forKey:.uvMapping),revision:try c.decode(Int.self,forKey:.revision),
            createdAt:try c.decode(Date.self,forKey:.createdAt),updatedAt:try c.decode(Date.self,forKey:.updatedAt))
        advanced=try c.decodeIfPresent(CADAdvancedMaterial.self,forKey:.advanced);nodeGraph=try c.decodeIfPresent(CADMaterialNodeGraph.self,forKey:.nodeGraph)
        if let nodeGraph { try nodeGraph.validate(requireBake:true);for (slot,sha) in nodeGraph.bakedSHA256 ?? [:] { guard textures.first(where:{$0.slot.rawValue==slot})?.sha256==sha else { throw CADMaterialGraphError.invalid } } }
    }
}
nonisolated extension CADMaterialLibrary {
    private enum AdvancedKeys:String,CodingKey { case schemaVersion,entries,updatedAt }
    init(from decoder:Decoder) throws {
        try CADMaterialStrict.keys(decoder,["schemaVersion","entries","updatedAt"])
        let c=try decoder.container(keyedBy:AdvancedKeys.self),version=try c.decode(Int.self,forKey:.schemaVersion)
        guard (1...2).contains(version) else { throw CADMaterialGraphError.invalid }
        let entries=try c.decode([CADMaterialDefinition].self,forKey:.entries)
        guard entries.count<=CADMaterialLimits.maximumLibraryEntries,!entries.contains(where:{$0.advanced != nil || $0.nodeGraph != nil}) || version>=2 else { throw CADMaterialGraphError.invalid }
        self.init(schemaVersion:version,entries:entries,updatedAt:try c.decode(Date.self,forKey:.updatedAt))
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

nonisolated struct CADSolidConversionProvenance:Codable,Sendable {
    var version=1
    let representation:String
    let toleranceMM:Double
    let sourceBodyIDs:[BodyID]
    let meshSource:CADHybridMeshSource?
    func validate() throws {
        guard version==1,["faceted","sewn-sheets"].contains(representation),toleranceMM.isFinite,
              (1e-7...1e-3).contains(toleranceMM),!sourceBodyIDs.isEmpty,sourceBodyIDs.count<=64,
              Set(sourceBodyIDs).count==sourceBodyIDs.count,
              (representation=="faceted")==(meshSource != nil) else {
            throw CADHybridFailure.invalid("The solid conversion record is invalid or requires a newer editor.")
        }
        try meshSource?.validate()
        if let meshSource,sourceBodyIDs != [meshSource.sourceBodyID] {
            throw CADHybridFailure.invalid("The stored mesh conversion source identity is inconsistent.")
        }
    }
    static func validateStoredJSONObject(_ raw:Any) throws {
        let value=try CADHybridStoredJSON.object(raw,keys:["version","representation","toleranceMM","sourceBodyIDs","meshSource"])
        guard let ids=value["sourceBodyIDs"] as? [Any],ids.count<=64 else {throw CADHybridFailure.invalid("Invalid stored conversion sources.")}
        for id in ids {try CADHybridStoredJSON.bodyID(id)}
        if let source=value["meshSource"],!(source is NSNull) {try CADHybridMeshSource.validateStoredJSONObject(source)}
        let data=try JSONSerialization.data(withJSONObject:raw)
        try JSONDecoder().decode(Self.self,from:data).validate()
    }
}

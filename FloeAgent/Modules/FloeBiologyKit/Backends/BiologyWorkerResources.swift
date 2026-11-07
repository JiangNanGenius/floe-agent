// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

/// Verified resources for the host's existing resolved Linux environment. This
/// type never launches an interpreter, installs packages or chooses an environment.
public enum BiologyWorkerResources {
    private struct Manifest:Decodable {
        struct Entry:Decodable {let file:String;let bytes:Int;let sha256:String}
        let schema:String
        let files:[Entry]
    }
    public static func verifiedFiles() throws -> [String:Data] {
        guard let url=Bundle.module.url(forResource:"worker-manifest",withExtension:"json") else {throw BiologyError.unavailable("Scientific worker resources are missing.")}
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url))
        guard manifest.schema=="floe.biology.worker.resources.v1",manifest.files.count<=16,Set(manifest.files.map(\.file)).count==manifest.files.count else {throw BiologyError.corrupt("Invalid scientific resource manifest.")}
        var output:[String:Data]=[:]
        for item in manifest.files {
            guard !item.file.contains("/"),!item.file.contains(".."),item.bytes>0,item.bytes<=2*1024*1024,
                  let resource=Bundle.module.url(forResource:item.file,withExtension:nil) else {throw BiologyError.corrupt("Invalid scientific resource entry.")}
            let values=try resource.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true,values.fileSize==item.bytes else {throw BiologyError.corrupt("Scientific resource size failed validation.")}
            let bytes=try Data(contentsOf:resource)
            guard BiologyProjectStore.digest(bytes)==item.sha256 else {throw BiologyError.corrupt("Scientific resource digest failed validation.")}
            output[item.file]=bytes
        }
        return output
    }
}

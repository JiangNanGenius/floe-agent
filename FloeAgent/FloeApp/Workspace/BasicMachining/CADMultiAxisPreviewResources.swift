// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeWorkbench

enum CADMultiAxisPreviewResources {
    static let wrapperSHA256="bf762f9f104c15608f617558dbe7db99cf6efb79786bf54254d53ad41d3414b5"
    static let motionSHA256="b31cb2f9829dd478d8de4419d763f7a20d1c693f77728b02e6eec9b0955332c8"
    static let fixtureSHA256="a3d40b2f5737e2c803772366dac7cf3f6128d1638b75f5d970abaa6b75445e60"
    static let files:[String:(String,Int)]=[
        "multi-axis-preview-backend-0.1.2.zip":("037850365248becbe34f97213967f41ca4313758ebed6fd38386c45bbc8fddc3",96761),
        "prepare-multi-axis-preview.sh":("2cfcbf3256b4f4097e85f64144d357ce68ced05590624e6f5fd855b47a724537",2954),
        "run-multi-axis-preview.sh":("77c9d24d8c76379f1a5dce62b26d8cc9b4e9f05b5b463cf95af092c996fb7ed2",2058),
    ]
    private static func resource(_ name:String)throws->URL {
        let u=Bundle.main.url(forResource:name,withExtension:nil,subdirectory:"BasicMachining") ?? Bundle.main.url(forResource:name,withExtension:nil)
        guard let u,let expected=files[name],try u.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true,try Data(contentsOf:u).count==expected.1,try FloeDigest.sha256Hex(ofFileAt:u)==expected.0 else{throw FloeError.validationFailed("The multi-axis preview resource package is missing or changed")}
        return u
    }
    static func validateBundle()throws {for name in files.keys{_=try resource(name)}}
    static func stage(into directory:URL)throws {try validateBundle();for name in files.keys{try Data(contentsOf:resource(name)).write(to:directory.appendingPathComponent(name),options:.atomic)}}
    static func taskRequest(fromBasicJSON text:String,parameters:CadBasicMachiningParameters)throws->String {
        guard let preview=parameters.preview,var q=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any] else{throw FloeError.validationFailed("Preview parameters unavailable")}
        q["schema"]="floe.cad-multi-axis-preview-task.v1";q.removeValue(forKey:"stock");q.removeValue(forKey:"tool");q.removeValue(forKey:"path")
        q["parameters"]=try preview.taskParameters(radius:parameters.radiusMM,length:parameters.lengthMM,resolution:parameters.resolutionMM)
        return String(decoding:try JSONSerialization.data(withJSONObject:q,options:.sortedKeys),as:UTF8.self)
    }
    static func payload(phase:CadBasicMachiningRequest.Phase,relativeDirectory:String,inputSHA:String)throws->Data {
        let parts=relativeDirectory.split(separator:"/")
        guard parts.count==2,parts[0]=="BasicMachining",UUID(uuidString:String(parts[1])) != nil,inputSHA.count==64,inputSHA.allSatisfy({$0.isHexDigit && !$0.isUppercase}) else{throw FloeError.unauthorized}
        let file=phase == .environment ? "prepare-multi-axis-preview.sh":"run-multi-axis-preview.sh"
        guard let sha=files[file]?.0 else{throw FloeError.unauthorized}
        let script="set -eu\n[ \"$(/usr/bin/shasum -a 256 '\(relativeDirectory)/support/\(file)' | /usr/bin/awk '{print $1}')\" = '\(sha)' ]\n/bin/sh '\(relativeDirectory)/support/\(file)' '\(relativeDirectory)' '\(inputSHA)'"
        return try JSONSerialization.data(withJSONObject:["script":script,"cwd":".","timeoutSeconds":phase == .environment ? 240:110,"timeoutPolicy":"hard","maxOutputBytes":16000],options:.sortedKeys)
    }
    static func verifyPreparation(directory:URL,inputSHA:String)throws {
        let file=directory.appendingPathComponent("environment-ready.json");guard file.standardizedFileURL==file.resolvingSymlinksInPath().standardizedFileURL else{throw FloeError.unauthorized}
        let data=try Data(contentsOf:file);guard data.count<=4096,let o=try JSONSerialization.jsonObject(with:data) as? [String:Any],o["schema"] as? String=="floe.multi-axis-preview-environment.v1",o["operationID"] as? String==directory.lastPathComponent,o["requestSHA256"] as? String==inputSHA,o["runtimeVersion"] as? String=="8.0.33",o["coreSHA256"] as? String==CADBasicMachiningResources.coreSHA256,o["wrapperSHA256"] as? String==wrapperSHA256,o["actualOS"] as? String=="Darwin",o["architecture"] as? String=="arm64" else{throw FloeError.validationFailed("The selected Mac environment did not return a verified multi-axis preview preparation receipt")}
    }
}

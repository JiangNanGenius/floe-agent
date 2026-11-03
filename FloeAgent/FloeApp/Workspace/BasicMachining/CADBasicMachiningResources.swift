// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeWorkbench

/// Pinned managed IL only. No .NET runtime, SDK, host interpreter or executable fallback is bundled.
enum CADBasicMachiningResources {
    static let version="0.2.0"
    static let coreSHA256="3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d"
    static let wrapperSHA256="3e8653b17d34a6786ee4a753660944c52172cff71e1f6ba431dc1de74b463cf9"
    static let files:[String:(String,Int)]=[
        "MillSimSharp-LICENSE.txt":("69dafaf55836c001236ca0872aeab7d2f93cab80e495b960ed452bada7c1909a",1062),
        "basic-machining-backend-0.2.0.zip":("da659f9f0b52ea0c696d20f3fee5a1523c8bf3cdd174858872d147e29e403770",49837),
        "dotnet-LICENSE.txt":("cfc21f5e8bd655ae997eec916138b707b1d290b83272c02a95c9f821b8c87310",1116),
        "prepare-basic-machining.sh":("3b0d61d965fbf871bbdb699975aaea63674b5dfd0a5858e70c5817519782c255",4991),
        "run-basic-machining.sh":("56cdd447f5012e2d4f5165827bc6818705b57843ae22a35d978d0feeead59c9e",2341),
        "runtime-SHA256SUMS":("dadef426a6c034f1dbf3dc36f117f108fc2ad1ffa9fea62b0e292ef1a14ad09d",24522)
    ]
    private static func resource(_ name:String)throws->URL {
        let url=Bundle.main.url(forResource:name,withExtension:nil,subdirectory:"BasicMachining") ?? Bundle.main.url(forResource:name,withExtension:nil)
        guard let url,let expected=files[name],try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true,
              try Data(contentsOf:url).count==expected.1,try FloeDigest.sha256Hex(ofFileAt:url)==expected.0 else {
            throw FloeError.validationFailed("The basic machining resource package is missing or changed")
        }
        return url
    }
    static func validateBundle()throws {for name in files.keys{_=try resource(name)}}
    static func stage(into directory:URL)throws {
        try validateBundle();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for name in files.keys {let data=try Data(contentsOf:resource(name));try data.write(to:directory.appendingPathComponent(name),options:.atomic)}
    }
    static func payload(phase:CadBasicMachiningRequest.Phase,relativeDirectory:String,inputSHA:String)throws->Data {
        let suffix=relativeDirectory.split(separator:"/")
        guard suffix.count==2,suffix[0]=="BasicMachining",UUID(uuidString:String(suffix[1])) != nil,
              inputSHA.count==64,inputSHA.allSatisfy({$0.isHexDigit && !$0.isUppercase}) else {throw FloeError.unauthorized}
        let file=phase == .environment ? "prepare-basic-machining.sh":"run-basic-machining.sh"
        guard let sha=files[file]?.0 else{throw FloeError.unauthorized}
        // All interpolated fields are restricted UUID/digest/domain constants, never supplied shell text.
        let script="set -eu\n[ \"$(/usr/bin/shasum -a 256 '\(relativeDirectory)/support/\(file)' | /usr/bin/awk '{print $1}')\" = '\(sha)' ]\n/bin/sh '\(relativeDirectory)/support/\(file)' '\(relativeDirectory)' '\(inputSHA)'"
        return try JSONSerialization.data(withJSONObject:["script":script,"cwd":".","timeoutSeconds":phase == .environment ? 240:60,"timeoutPolicy":"hard","maxOutputBytes":16_000],options:.sortedKeys)
    }
    static func verifyPreparation(directory:URL,inputSHA:String)throws {
        let file=directory.appendingPathComponent("environment-ready.json")
        guard file.standardizedFileURL==file.resolvingSymlinksInPath().standardizedFileURL else{throw FloeError.unauthorized}
        let data=try Data(contentsOf:file);guard data.count<=4096,let o=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              o["schema"] as? String=="floe.basic-machining-environment.v1",o["operationID"] as? String==directory.lastPathComponent,
              o["requestSHA256"] as? String==inputSHA,o["runtimeVersion"] as? String=="8.0.33",
              o["coreSHA256"] as? String==coreSHA256,o["wrapperSHA256"] as? String==wrapperSHA256,
              o["actualOS"] as? String=="Darwin",o["architecture"] as? String=="arm64" else {
            throw FloeError.validationFailed("The selected Mac environment did not return a verified preparation receipt")
        }
    }
}

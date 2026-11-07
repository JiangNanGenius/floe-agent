// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public struct BiologyToolDescriptor: Codable, Sendable {
    public var name:String
    public var description:String
    public var parameters:JSONValue = .object([:])
}
/// Adapt into Floe's existing catalog. Scope comes from the host, not arguments.
public actor BiologyToolSession {
    private let service:BiologyService
    private var projects:Set<UUID>
    private let owner:BiologyExecutionOwner
    private let canCreate:Bool
    public init(service:BiologyService,authorizedProjectIDs:Set<UUID>,owner:BiologyExecutionOwner,canCreate:Bool = false) {
        self.service=service;projects=authorizedProjectIDs;self.owner=owner;self.canCreate=canCreate
    }
    public func descriptors() -> [BiologyToolDescriptor] {
        var list=[
            BiologyToolDescriptor(name:"biology.read",description:"Read authorized datasets and actual results."),
            .init(name:"biology.methods",description:"Discover currently configured native/scientific methods."),
            .init(name:"biology.import",description:"Import actual inline file bytes into an authorized project."),
            .init(name:"biology.edit",description:"Edit a sequence or project notes with an expected revision."),
            .init(name:"biology.analyze",description:"Start a real calculation owned by the current task."),
            .init(name:"biology.job",description:"Await or cancel a calculation owned by the current task."),
            .init(name:"biology.derive",description:"Save a supported successful result as a new dataset after verifying its input revision."),
            .init(name:"biology.export",description:"Export actual bytes with size and checksum.")
        ]
        if canCreate {list.append(.init(name:"biology.create",description:"Create a biology project in this session's authorized scope."))}
        for i in list.indices {list[i].parameters=Self.schema(list[i].name)}
        return list
    }
    private static func schema(_ name:String)->JSONValue {
        var properties:[String:JSONValue]=["projectID":.object(["type":.string("string")])]
        var required=["projectID"]
        let keys:[String]
        switch name {
        case "biology.create":properties=[:];keys=["title"];required=["title"]
        case "biology.read":keys=["assetID","runID"]
        case "biology.methods":keys=["assetID"]
        case "biology.import":keys=["title","format","base64"];required += keys
        case "biology.edit":keys=["assetID","notes","replacement"];required += ["expectedRevision"]
        case "biology.analyze":keys=["assetID","method","environmentID"];required += ["assetID","method","expectedRevision"]
        case "biology.job":keys=["runID","action"];required += ["runID"]
        case "biology.derive":keys=["runID"];required += ["runID","expectedRevision"]
        default:keys=["assetID","format"]
        }
        for key in keys {properties[key] = .object(["type":.string("string")])}
        if required.contains("expectedRevision") {properties["expectedRevision"] = .object(["type":.string("integer"),"minimum":.number(1)])}
        if name=="biology.edit" {for key in ["record","start","end"]{properties[key] = .object(["type":.string("integer"),"minimum":.number(0)])}}
        if name=="biology.analyze" {properties["options"] = .object(["type":.string("object")])}
        return .object(["type":.string("object"),"properties":.object(properties),"required":.array(required.map(JSONValue.string)),"additionalProperties":.bool(false)])
    }
    private func bounded<T:Encodable>(_ value:T) throws -> JSONValue {
        let data=try BiologyCoding.encode(value)
        guard data.count<=2*1024*1024 else {throw BiologyError.unavailable("This dataset exceeds the inline response budget. Use the host's scoped file tools or export.")}
        return try JSONDecoder().decode(JSONValue.self,from:data)
    }
    private func metadata(_ asset:BiologyAsset) throws -> JSONValue {
        .object(["id":.string(asset.id.uuidString),"title":.string(asset.title),"revision":.number(Double(asset.revision)),"kind":.string(asset.kind.rawValue),"originalFormat":.string(asset.originalFormat),"originalBytes":.number(Double(asset.originalData.count)),"warnings":try BiologyCoding.json(asset.warnings),"provenance":try BiologyCoding.json(asset.provenance)])
    }
    private func metadata(_ project:BiologyProject) throws -> JSONValue {
        let runs=project.runs.map {run in JSONValue.object(["id":.string(run.id.uuidString),"assetID":.string(run.assetID.uuidString),"assetRevision":.number(Double(run.assetRevision)),"method":.string(run.method),"environmentID":.string(run.environmentID),"status":.string(run.status.rawValue)])}
        return try bounded(JSONValue.object(["id":.string(project.id.uuidString),"title":.string(project.title),"revision":.number(Double(project.revision)),"notes":.string(project.notes),"chemistryLinks":try BiologyCoding.json(project.chemistryLinks),"assets":.array(try project.assets.map{try metadata($0)}),"runs":.array(runs)]))
    }
    public func invoke(name:String,arguments:JSONValue) async throws -> JSONValue {
        guard (try BiologyCoding.encode(arguments)).count<=2*1024*1024 else {throw BiologyError.invalid("Tool arguments exceed the inline limit.")}
        if name=="biology.create" {
            guard canCreate,let title=arguments["title"]?.string else {throw BiologyError.unavailable("This session cannot create projects.")}
            let p=try await service.create(title:title);projects.insert(p.id);return try BiologyCoding.json(p)
        }
        guard let text=arguments["projectID"]?.string,let id=UUID(uuidString:text),projects.contains(id) else {throw BiologyError.unavailable("This project is outside the task's authorized scope.")}
        let p=try await service.project(id)
        if name=="biology.read" {
            if let raw=arguments["assetID"]?.string,let asset=p.assets.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) {
                var json=try metadata(asset).object ?? [:];json["payload"]=try bounded(asset.payload);return try bounded(JSONValue.object(json))
            }
            if let raw=arguments["runID"]?.string,let run=p.runs.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) {return try bounded(run)}
            if arguments["assetID"] != nil || arguments["runID"] != nil {throw BiologyError.invalid("Dataset or calculation does not exist.")}
            return try metadata(p)
        }
        if name=="biology.methods" {
            if let raw=arguments["assetID"]?.string,let asset=p.assets.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) {return try bounded(await service.capabilities(for:asset))}
            return try bounded(await service.capabilities())
        }
        if name=="biology.import" {
            guard let title=arguments["title"]?.string,let format=arguments["format"]?.string,let encoded=arguments["base64"]?.string,let data=Data(base64Encoded:encoded) else {throw BiologyError.invalid("Title, format and valid base64 bytes are required.")}
            return try metadata(await service.importAsset(id,title:title,format:format,data:data,provenance:["taskID":owner.taskID.uuidString,"hostRunID":owner.hostRunID.uuidString]))
        }
        if name=="biology.derive" {
            guard let raw=arguments["runID"]?.string,let run=p.runs.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}),run.owner==owner,
                  let revision=arguments["expectedRevision"]?.number,revision.isFinite,revision>=1,revision<=Double(Int.max),revision.rounded()==revision,UInt64(revision)==run.assetRevision else {throw BiologyError.invalid("Choose this task's result and its exact input revision.")}
            return try metadata(await service.deriveAsset(id,runID:run.id))
        }
        if name=="biology.edit" {
            guard let revision=arguments["expectedRevision"]?.number,revision.isFinite,revision>=0,revision.rounded()==revision,revision<=Double(Int.max) else {throw BiologyError.invalid("Expected revision is required.")}
            if let notes=arguments["notes"]?.string {try await service.saveNotes(id,text:notes,expectedRevision:UInt64(revision));return try metadata(await service.project(id))}
            guard let a=arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),let replacement=arguments["replacement"]?.string else {throw BiologyError.invalid("Choose a sequence and replacement.")}
            func index(_ key:String,_ fallback:Int) throws -> Int {
                guard let n=arguments[key]?.number else {return fallback}
                guard n.isFinite,n>=0,n<=2_000_000,n.rounded()==n else {throw BiologyError.invalid("Invalid sequence coordinate.")};return Int(n)
            }
            try await service.editSequence(id,assetID:a,expectedAssetRevision:UInt64(revision),record:index("record",0),start:index("start",0),end:index("end",0),replacement:replacement)
            return try metadata(await service.project(id))
        }
        if name=="biology.analyze" {
            guard let a=arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),let asset=p.assets.first(where:{$0.id==a}),let method=arguments["method"]?.string else {throw BiologyError.invalid("Choose a dataset and method.")}
            guard let revision=arguments["expectedRevision"]?.number,revision.isFinite,revision>=1,revision<=Double(Int.max),revision.rounded()==revision,UInt64(revision)==asset.revision else {throw BiologyError.invalid("The dataset changed; read its current revision first.")}
            return try BiologyCoding.json(await service.start(id,assetID:a,expectedAssetRevision:asset.revision,method:method,options:arguments["options"] ?? .object([:]),environmentID:arguments["environmentID"]?.string ?? "native.local",owner:owner))
        }
        if name=="biology.job" {
            guard let runID=arguments["runID"]?.string.flatMap(UUID.init(uuidString:)),let run=p.runs.first(where:{$0.id==runID}),run.owner==owner else {throw BiologyError.unavailable("This calculation is not owned by the current task.")}
            if arguments["action"]?.string=="cancel" {try await service.cancel(id,runID:runID)}
            return try bounded(await service.wait(id,runID:runID))
        }
        if name=="biology.export" {
            let data:Data
            if let raw=arguments["assetID"]?.string,let a=UUID(uuidString:raw) {data=try await service.exportAsset(id,assetID:a,format:arguments["format"]?.string ?? "original")}
            else {data=try await service.exportProject(id)}
            guard data.count<=2*1024*1024 else {throw BiologyError.unavailable("Use the host file-export callback for files larger than 2 MiB.")}
            return .object(["bytes":.number(Double(data.count)),"sha256":.string(BiologyProjectStore.digest(data)),"base64":.string(data.base64EncodedString())])
        }
        throw BiologyError.unavailable("Unknown biology tool.")
    }
}

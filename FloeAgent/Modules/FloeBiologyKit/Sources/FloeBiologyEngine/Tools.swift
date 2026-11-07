// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public struct BiologyToolDescriptor: Codable, Sendable {
    public var name:String
    public var description:String
    public var parameters:JSONValue = .object([:])
    public var isReadOnly:Bool {BiologyToolSchemas.readOnlyNames.contains(name)}
}
/// Adapt into Floe's existing catalog. Scope comes from the host, not arguments.
public actor BiologyToolSession {
    let service:BiologyService
    var projects:Set<UUID>
    let owner:BiologyExecutionOwner
    private let canCreate:Bool
    let readOnly:Bool
    private let isCancelled:@Sendable ()->Bool
    public init(service:BiologyService,authorizedProjectIDs:Set<UUID>,owner:BiologyExecutionOwner,canCreate:Bool = false,readOnly:Bool=false,isCancelled:@escaping @Sendable ()->Bool = {false}) {
        self.service=service;projects=authorizedProjectIDs;self.owner=owner;self.canCreate=canCreate && !readOnly;self.readOnly=readOnly;self.isCancelled=isCancelled
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
        list+=Self.extendedDescriptors()
        if canCreate {list.append(.init(name:"biology.importProject",description:"Import a saved project; historical runs never gain current task ownership."))}
        for i in list.indices {list[i].parameters=BiologyToolSchemas.schema(list[i].name) ?? Self.schema(list[i].name)}
        return readOnly ? list.filter(\.isReadOnly):list
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
    func bounded<T:Encodable>(_ value:T) throws -> JSONValue {
        let data=try BiologyCoding.encode(value)
        guard data.count<=2*1024*1024 else {throw BiologyError.unavailable("This dataset exceeds the inline response budget. Use the host's scoped file tools or export.")}
        return try JSONDecoder().decode(JSONValue.self,from:data)
    }
    func metadata(_ asset:BiologyAsset) throws -> JSONValue {
        var value:[String:JSONValue]=["id":.string(asset.id.uuidString),"title":.string(asset.title),"revision":.number(Double(asset.revision)),"kind":.string(asset.kind.rawValue),"originalFormat":.string(asset.originalFormat),"originalBytes":.number(Double(asset.fileReference?.byteCount ?? UInt64(asset.originalData.count))),"warnings":try BiologyCoding.json(asset.warnings),"provenance":try BiologyCoding.json(asset.provenance)]
        if let reference=asset.fileReference {value["fileReference"]=try BiologyCoding.json(reference)}
        return .object(value)
    }
    func metadata(_ project:BiologyProject) throws -> JSONValue {
        let runs=project.runs.map {run in JSONValue.object(["id":.string(run.id.uuidString),"assetID":.string(run.assetID.uuidString),"assetRevision":.number(Double(run.assetRevision)),"method":.string(run.method),"environmentID":.string(run.environmentID),"status":.string(run.status.rawValue)])}
        return try bounded(JSONValue.object(["id":.string(project.id.uuidString),"title":.string(project.title),"revision":.number(Double(project.revision)),"activeAssetID":project.activeAssetID.map{.string($0.uuidString)} ?? .null,"activeSelection":project.activeAssetID.flatMap{project.selections?[$0.uuidString]} ?? .null,"notes":.string(project.notes),"chemistryLinks":try BiologyCoding.json(project.chemistryLinks),"assets":.array(try project.assets.map{try metadata($0)}),"runs":.array(runs)]))
    }
    public func invoke(name:String,arguments:JSONValue,requestID:String? = nil) async throws -> JSONValue {
        guard (try BiologyCoding.encode(arguments)).count<=2*1024*1024 else {throw BiologyError.invalid("Tool arguments exceed the inline limit.")}
        guard let descriptor=descriptors().first(where:{$0.name==name}) else {throw BiologyError.unavailable("This tool is unavailable in the current task scope or read-only context.")}
        try BiologyToolSchemas.validate(arguments,against:descriptor.parameters)
        try Task.checkCancellation()
        if isCancelled(){throw CancellationError()}
        let identity=BiologyMutationIdentity(owner:owner,requestID:requestID ?? UUID().uuidString,argumentDigest:BiologyProjectStore.digest(try BiologyCoding.encode(JSONValue.object(["tool":.string(name),"arguments":arguments]))))
        if name=="biology.create" {
            guard canCreate,let title=arguments["title"]?.string else {throw BiologyError.unavailable("This session cannot create projects.")}
            let p=try await service.create(title:title,identity:identity);projects.insert(p.id);return try metadata(p)
        }
        if name=="biology.importProject" {
            guard canCreate else {throw BiologyError.unavailable("This task cannot import new projects.")}
            let project:BiologyProject
            if let fileID=arguments["fileID"]?.string.flatMap(UUID.init(uuidString:)),let source=arguments["sourceProjectID"]?.string.flatMap(UUID.init(uuidString:)),projects.contains(source),arguments["base64"]==nil {
                project=try await service.importProjectFile(source,fileID:fileID,owner:owner,identity:identity)
            } else if arguments["fileID"]==nil,arguments["sourceProjectID"]==nil,let encoded=arguments["base64"]?.string,let data=Data(base64Encoded:encoded) {
                project=try await service.importProject(data,identity:identity)
            } else {throw BiologyError.invalid("Choose actual base64 bytes, or fileID and sourceProjectID within this task's authorized scope.")}
            projects.insert(project.id);return try metadata(project)
        }
        if let result=try await invokeExtended(name:name,arguments:arguments,identity:identity) {return result}
        guard let text=arguments["projectID"]?.string,let id=UUID(uuidString:text),projects.contains(id) else {throw BiologyError.unavailable("This project is outside the task's authorized scope.")}
        let p=try await service.project(id)
        if name=="biology.read" {
            return try await readPage(p,arguments:arguments)
        }
        if name=="biology.methods" {
            let available:[String:[String]]
            if let raw=arguments["assetID"]?.string {
                guard let asset=p.assets.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) else {throw BiologyError.invalid("Dataset no longer exists.")}
                available=await service.capabilities(for:asset)
            }else{available=await service.capabilities()}
            return try bounded(JSONValue.object(["environments":try BiologyCoding.json(available),"methods":.array(Set(available.values.flatMap{$0}).sorted().map{BiologyMethodCatalog.describe($0)})]))
        }
        if name=="biology.import" {
            if let text=arguments["fileID"]?.string,let fileID=UUID(uuidString:text),let title=arguments["title"]?.string,let format=arguments["format"]?.string {
                guard arguments["base64"]==nil else {throw BiologyError.invalid("Choose fileID or base64, not both.")}
                return try metadata(await service.importFile(id,fileID:fileID,title:title,format:format,owner:owner,identity:identity))
            }
            guard let title=arguments["title"]?.string,let format=arguments["format"]?.string,let encoded=arguments["base64"]?.string,let data=Data(base64Encoded:encoded) else {throw BiologyError.invalid("Title, format and valid base64 bytes are required.")}
            return try metadata(await service.importAsset(id,title:title,format:format,data:data,provenance:["taskID":owner.taskID.uuidString,"hostRunID":owner.hostRunID.uuidString],identity:identity))
        }
        if name=="biology.derive" {
            guard let raw=arguments["runID"]?.string,let run=p.runs.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}),run.owner==owner,
                  let revision=arguments["expectedRevision"]?.number,revision.isFinite,revision>=1,revision<=Double(Int.max),revision.rounded()==revision,UInt64(revision)==run.assetRevision else {throw BiologyError.invalid("Choose this task's result and its exact input revision.")}
            return try metadata(await service.deriveAsset(id,runID:run.id,identity:identity))
        }
        if name=="biology.edit" {
            guard let revision=arguments["expectedRevision"]?.number,revision.isFinite,revision>=0,revision.rounded()==revision,revision<=Double(Int.max) else {throw BiologyError.invalid("Expected revision is required.")}
            if let notes=arguments["notes"]?.string {_=try await service.update(id,operation:"project.notes",assetID:nil,expectedRevision:UInt64(revision),parameters:.object(["text":.string(notes)]),identity:identity);return try metadata(await service.project(id))}
            guard let a=arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),let replacement=arguments["replacement"]?.string else {throw BiologyError.invalid("Choose a sequence and replacement.")}
            func index(_ key:String,_ fallback:Int) throws -> Int {
                guard let n=arguments[key]?.number else {return fallback}
                guard n.isFinite,n>=0,n<=2_000_000,n.rounded()==n else {throw BiologyError.invalid("Invalid sequence coordinate.")};return Int(n)
            }
            try await service.editSequence(id,assetID:a,expectedAssetRevision:UInt64(revision),record:index("record",0),start:index("start",0),end:index("end",0),replacement:replacement,identity:identity)
            return try metadata(await service.project(id))
        }
        if name=="biology.analyze" {
            guard let a=arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),let asset=p.assets.first(where:{$0.id==a}),let method=arguments["method"]?.string else {throw BiologyError.invalid("Choose a dataset and method.")}
            guard let revision=arguments["expectedRevision"]?.number,revision.isFinite,revision>=1,revision<Double(Int.max),revision.rounded()==revision else {throw BiologyError.invalid("Read the dataset revision before starting a calculation.")}
            let options=arguments["options"] ?? .object([:]);try BiologyMethodCatalog.validate(options,method:method)
            _ = asset
            return try BiologyCoding.json(await service.start(id,assetID:a,expectedAssetRevision:UInt64(revision),method:method,options:options,environmentID:arguments["environmentID"]?.string ?? "native.local",owner:owner,identity:identity,cancellationCheck:isCancelled))
        }
        if name=="biology.job" {
            guard let runID=arguments["runID"]?.string.flatMap(UUID.init(uuidString:)),let run=p.runs.first(where:{$0.id==runID}),run.owner==owner else {throw BiologyError.unavailable("This calculation is not owned by the current task.")}
            switch arguments["action"]?.string ?? "wait" {
            case "cancel":if run.isActive {try await service.cancel(id,runID:runID)};return try runMetadata(await service.wait(id,runID:runID))
            case "status":return try runMetadata(run)
            case "wait":return try await withTaskCancellationHandler {try runMetadata(await service.wait(id,runID:runID))}onCancel:{[service] in Task{try? await service.cancel(id,runID:runID)}}
            default:throw BiologyError.invalid("Choose status, wait or cancel.")
            }
        }
        if name=="biology.export" {
            guard arguments["assetID"]==nil || arguments["runID"]==nil else {throw BiologyError.invalid("Choose a dataset or a result.")}
            let referenced=arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)).flatMap{selected in p.assets.first(where:{$0.id==selected})?.fileReference} != nil
            if arguments["destination"]?.string=="file" || (referenced && (arguments["format"]?.string ?? "original")=="original") {
                return try bounded(await service.exportFile(id,assetID:arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),runID:arguments["runID"]?.string.flatMap(UUID.init(uuidString:)),format:arguments["format"]?.string ?? (arguments["runID"]==nil ? "original":"json"),owner:owner,identity:identity))
            }
            let data:Data
            if let raw=arguments["assetID"]?.string,let a=UUID(uuidString:raw) {data=try await service.exportAsset(id,assetID:a,format:arguments["format"]?.string ?? "original")}
            else if let runID=arguments["runID"]?.string.flatMap(UUID.init(uuidString:)),let result=p.runs.first(where:{$0.id==runID})?.result {
                switch arguments["format"]?.string ?? "json" {case "json":data=try BiologyCoding.encode(result);case "csv":data=Data(result.csv().utf8);case "text":data=Data(result.text.utf8);default:throw BiologyError.invalid("Choose json, csv or text for a result.")}
            } else if arguments["runID"] != nil {throw BiologyError.invalid("No saved result is available.")}
            else {data=try await service.exportProject(id)}
            guard data.count<=1_500_000 else {
                return try bounded(await service.exportFile(id,assetID:arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),runID:arguments["runID"]?.string.flatMap(UUID.init(uuidString:)),format:arguments["format"]?.string ?? (arguments["runID"]==nil ? "original":"json"),owner:owner,identity:identity))
            }
            return .object(["bytes":.number(Double(data.count)),"sha256":.string(BiologyProjectStore.digest(data)),"base64":.string(data.base64EncodedString())])
        }
        throw BiologyError.unavailable("Unknown biology tool.")
    }
}

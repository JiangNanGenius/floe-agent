// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

extension BiologyToolSession {
    static func extendedDescriptors()->[BiologyToolDescriptor] {
        [
            .init(name:"biology.describe",description:"Read complete structured-edit parameter schemas, coordinate conventions, file formats and the full biology workflow. Call before editing a new domain."),
            .init(name:"biology.projects",description:"List only projects authorized to this task."),
            .init(name:"biology.update",description:"Validated, revision-checked edits for every domain. Supported operations: project rename/notes/chemistry link; blank asset create (sequence with optional first annotation, starter network); asset rename/delete/typed replacement; annotation upsert/remove; image calibration; matrix subset as a new dataset; typed network replacement; rigid structure transformation. Originals are retained."),
            .init(name:"biology.select",description:"Persist a dataset/range/atom/plane/region/gene/cell selection for the native workbench without changing source data."),
            .init(name:"biology.status",description:"Read a current task-owned calculation's actual state without waiting."),
            .init(name:"biology.stop",description:"Stop this task's calculation and wait for an actual owned-worker stop acknowledgement."),
            .init(name:"biology.history",description:"Read saved project revision identifiers with pagination."),
            .init(name:"biology.restore",description:"Restore a saved revision with CAS; current source revisions remain monotonic and active workers block restoration."),
            .init(name:"biology.deleteProject",description:"Move an authorized project to recoverable Recently Deleted; active workers block deletion."),
            .init(name:"biology.deleted",description:"List only this task's authorized projects in Recently Deleted."),
            .init(name:"biology.restoreDeleted",description:"Restore an authorized project from Recently Deleted without granting new project authority."),
            .init(name:"biology.file.read",description:"Read a bounded byte range of a host-authorized opaque file handle, returning actual bytes and the range digest.")
        ]
    }
    func scope(_ arguments:JSONValue) throws -> UUID {
        guard let raw=arguments["projectID"]?.string,let id=UUID(uuidString:raw),projects.contains(id) else {throw BiologyError.unavailable("Project is outside this task's authorized scope.")};return id
    }
    func integer(_ arguments:JSONValue,_ key:String,default fallback:Int? = nil,range:ClosedRange<Int>=0...Int.max) throws -> Int {
        if arguments[key]==nil,let fallback {return fallback}
        guard let n=arguments[key]?.number,n.isFinite,n.rounded()==n,n>=Double(range.lowerBound),n<Double(Int.max),n<=Double(range.upperBound) else {throw BiologyError.invalid("Invalid integer argument: "+key)};return Int(n)
    }
    func invokeExtended(name:String,arguments:JSONValue,identity:BiologyMutationIdentity) async throws -> JSONValue? {
        if name=="biology.describe" {if let op=arguments["operation"]?.string {return try BiologyEditCatalog.schema(op)};return try BiologyEditCatalog.describe()}
        if name=="biology.projects" {
            var list:[JSONValue]=[]
            for id in projects.sorted(by:{$0.uuidString<$1.uuidString}) {
                if let p=try? await service.project(id) {list.append(try metadata(p))}
            }
            return try bounded(JSONValue.array(list))
        }
        if name=="biology.deleted" {
            return try bounded(await service.deletedProjects().filter{projects.contains($0.projectID)})
        }
        let known:Set<String>=["biology.update","biology.select","biology.status","biology.stop","biology.history","biology.restore","biology.deleteProject","biology.restoreDeleted","biology.file.read"]
        guard known.contains(name) else {return nil}
        let id=try scope(arguments)
        if name=="biology.restoreDeleted" {
            guard let trash=arguments["trashID"]?.string else {throw BiologyError.invalid("A deleted project identity is required.")}
            return try metadata(await service.restoreDeleted(trash,projectID:id,identity:identity))
        }
        if name=="biology.deleteProject" {
            try await service.delete(id,expectedRevision:UInt64(integer(arguments,"expectedRevision",range:1...Int.max)),identity:identity)
            return .object(["deletedProjectID":.string(id.uuidString)])
        }
        if name=="biology.update" {
            guard let operation=arguments["operation"]?.string,let parameters=arguments["parameters"] else {throw BiologyError.invalid("Operation and its structured parameters are required.")}
            return try await service.update(id,operation:operation,assetID:arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),expectedRevision:UInt64(integer(arguments,"expectedRevision",range:1...Int.max)),parameters:parameters,identity:identity)
        }
        if name=="biology.select" {
            guard let assetID=arguments["assetID"]?.string.flatMap(UUID.init(uuidString:)),let selection=arguments["selection"] else {throw BiologyError.invalid("Dataset and selection are required.")}
            return try await service.select(id,assetID:assetID,selection:selection,expectedAssetRevision:UInt64(integer(arguments,"expectedRevision",range:1...Int.max)),identity:identity)
        }
        if name=="biology.history" {
            let history=try await service.history(id),offset=try integer(arguments,"offset",default:0),limit=try integer(arguments,"limit",default:50,range:1...100)
            guard offset<=history.count else {throw BiologyError.invalid("History offset exceeds its total count.")}
            return .object(["revisions":.array(history.dropFirst(offset).prefix(limit).map{.number(Double($0))}),"total":.number(Double(history.count)),"nextOffset":offset+limit<history.count ? .number(Double(offset+limit)):.null])
        }
        if name=="biology.restore" {
            return try metadata(await service.restore(id,revision:UInt64(integer(arguments,"revision",range:1...Int.max)),expectedRevision:UInt64(integer(arguments,"expectedRevision",range:1...Int.max)),identity:identity))
        }
        if name=="biology.file.read" {
            guard let fileID=arguments["fileID"]?.string.flatMap(UUID.init(uuidString:)) else {throw BiologyError.invalid("An authorized file UUID is required.")}
            let offset=try integer(arguments,"offset"),length=try integer(arguments,"length",range:1...196608)
            let data=try await service.readFile(id,fileID:fileID,offset:UInt64(offset),length:length,owner:owner)
            return .object(["bytes":.number(Double(data.count)),"offset":.number(Double(offset)),"sha256":.string(BiologyProjectStore.digest(data)),"base64":.string(data.base64EncodedString())])
        }
        let p=try await service.project(id)
        guard let runID=arguments["runID"]?.string.flatMap(UUID.init(uuidString:)),let run=p.runs.first(where:{$0.id==runID}),run.owner==owner else {throw BiologyError.unavailable("Calculation is not owned by this task and run.")}
        if name=="biology.stop",run.isActive {try await service.cancel(id,runID:runID);return try runMetadata(await service.wait(id,runID:runID))}
        return try runMetadata(run)
    }
    func runMetadata(_ run:BiologyRun) throws -> JSONValue {
        var value=try BiologyCoding.json(run).object ?? [:]
        if let result=run.result,(try BiologyCoding.encode(result)).count>262144 {
            value["result"] = .object(["summary":.string(result.summary),"metrics":try BiologyCoding.json(result.metrics),"columns":try BiologyCoding.json(result.columns),"totalRows":.number(Double(result.rows.count)),"textCharacters":.number(Double(result.text.count)),"paged":.bool(true)])
        }
        return try bounded(JSONValue.object(value))
    }
}

public extension BiologyService {
    func readFile(_ projectID:UUID,fileID:UUID,offset:UInt64,length:Int,owner:BiologyExecutionOwner?) async throws -> Data {
        try await permit(.read,projectID)
        guard let fileAccess else {throw BiologyError.unavailable("This host has not connected its authorized file service.")}
        let context=BiologyFileContext(projectID:projectID,owner:owner),reference=try await fileAccess.resolve(fileID,context:context)
        return try await fileAccess.read(reference,offset:offset,length:length,context:context)
    }
}

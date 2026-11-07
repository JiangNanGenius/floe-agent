// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD
import FloeCore
import FloeTools
import FloeManufacturingCore
import FloeManufacturingUI

/// Called only after StudioCoordinator resolves the actual CAD record and
/// performs the existing task/catalog/grant checks. No path comes from JSON.
@MainActor enum StudioManufacturingResearchContract {
    nonisolated enum Action:String,Codable,CaseIterable,Sendable {
        case inspect = "research.inspect",status = "research.status",configure = "research.configure"
        case calculate = "research.calculate",cancel = "research.cancel",save = "research.save",openSaved = "research.openSaved"
        var isReadOnly:Bool { self == .inspect || self == .status }
    }
    nonisolated struct Request:Decodable,Sendable {
        let family:ManufacturingResearchFamily
        let expectedFingerprint:String?
        let inputJSON:String?
        let operationID:UUID?
        let content:String?
        let offset:Int?
        let limit:Int?
        static func decode(_ text:String?) throws -> Self {
            guard let text,text.utf8.count <= 2 * 1_024 * 1_024,
                  let object = try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],
                  Set(object.keys).isSubset(of:["family","expectedFingerprint","inputJSON","operationID","content","offset","limit"]) else {
                throw FloeError.validationFailed("Use researchJSON {family,expectedFingerprint?,inputJSON?,operationID?,content?,offset?,limit?}; no path is accepted.")
            }
            let request = try JSONDecoder().decode(Self.self,from:Data(text.utf8))
            guard ["input","result","savedInput","savedResult"].contains(request.content ?? "input"),
                  (request.offset ?? 0) >= 0,(1...12_000).contains(request.limit ?? 12_000) else {
                throw FloeError.validationFailed("Use research content input/result/savedInput/savedResult and a bounded character page.")
            }
            return request
        }
        func validate(action:Action) throws {
            if action.isReadOnly {
                guard inputJSON == nil,operationID == nil else { throw FloeError.validationFailed("Research inspection reads the current or saved program; it does not accept editing inputs or a cancellation request.") }
            } else {
                guard expectedFingerprint?.isEmpty == false else { throw ManufacturingError.stale }
                if action == .configure { guard inputJSON != nil,operationID == nil else { throw PersonalContentError.invalidProject } }
                else { guard inputJSON == nil else { throw FloeError.validationFailed("Use research.configure to change parameters before this operation.") } }
                if action == .cancel { guard operationID != nil else { throw FloeError.validationFailed("Use the exact operationID from research.status.") } }
                else { guard operationID == nil else { throw FloeError.validationFailed("operationID is only used for research.cancel.") } }
            }
        }
    }
    nonisolated struct Saved:Codable,Sendable {
        let status:String
        let archiveSHA256:String?
        let archiveByteCount:Int
        let draftSHA256:String?
        let savedInputSHA256:String?
        let savedInputMatchesActive:Bool
        let sourceRelation:String
    }
    nonisolated struct Response:Codable,Sendable {
        let ownerCADProjectID:UUID
        let action:Action
        let family:ManufacturingResearchFamily
        let fingerprint:String
        let active:ManufacturingResearchSessions.Snapshot
        let saved:Saved
        let contentKind:String
        let contentJSON:String?
        let nextOffset:Int?
        let totalCharacters:Int
        let configurationSaved:Bool
        let resultSaved:Bool
        let actions:[String]
    }
    private nonisolated struct SavedFiles:Sendable {
        var archive:Data?,draft:Data?,input:Data?,result:Data?
        var archiveSHA256:String?,draftSHA256:String?,inputSHA256:String?
    }
    private nonisolated struct Fingerprint:Encodable {
        let owner:UUID,family:ManufacturingResearchFamily,active:String,archive:String?,draft:String?
    }
    static func perform(action:Action,request:Request,document:FloeCADDocument,ownerID:UUID,projectDirectory:URL,
                        context:ToolContext,validateSource:@escaping @MainActor ()async throws->Void) async throws -> Data {
        try request.validate(action:action)
        guard document.url == projectDirectory.appendingPathComponent("Document.floecad"),!document.isClosed else { throw PersonalContentError.changedDocument }
        let fileUse = try PersonalLibraryFileActions.acquireUse(id:ownerID,directory:projectDirectory)
        defer { fileUse.release() }
        try context.cancellation.throwIfCancelled();try Task.checkCancellation();try await validateSource()
        let directory = projectDirectory.appendingPathComponent("Manufacturing",isDirectory:true)
        let sessions = try ManufacturingSessions.researchSessions(document:document,directory:directory,ownerID:ownerID)
        try sessions.requireOwner(directory:directory,documentID:"cad:"+ownerID.uuidString.lowercased())
        let revision = document.revision,changes = document.exchangeChangeCount,source = document.contentSHA256
        let checkDocument:@MainActor ()throws->Void = {
            try context.cancellation.throwIfCancelled();try Task.checkCancellation()
            guard !document.isClosed,document.revision == revision,document.exchangeChangeCount == changes,document.contentSHA256 == source else {
                throw PersonalContentError.changedDocument
            }
        }
        var files = try await savedFiles(family:request.family,cadURL:document.url,projectDirectory:projectDirectory,cancellation:context.cancellation)
        try checkDocument();try await validateSource()
        var active = try sessions.snapshot(request.family)
        if active.state == "none" {
            if let draft = files.draft {
                // Retain a result only when the persisted draft is exactly its
                // actual source. Otherwise it remains a separate saved result.
                if let archive = files.archive,files.inputSHA256 == (try inputDigest(draft,family:request.family)) {
                    active = try sessions.adoptSaved(request.family,data:archive,isArchive:true,expectedFingerprint:active.fingerprint)
                } else { active = try sessions.adoptSaved(request.family,data:draft,isArchive:false,expectedFingerprint:active.fingerprint) }
            } else if let archive = files.archive {
                active = try sessions.adoptSaved(request.family,data:archive,isArchive:true,expectedFingerprint:active.fingerprint)
            }
        }
        let expectedFiles = files
        let initialFingerprint = try fingerprint(ownerID,request.family,active,files)
        if !action.isReadOnly || request.expectedFingerprint != nil {
            guard request.expectedFingerprint == initialFingerprint else { throw ManufacturingError.stale }
        }
        var configurationSaved = false,resultSaved = false
        switch action {
        case .inspect,.status: break
        case .openSaved:
            guard let archive = files.archive else { throw FloeError.validationFailed("No saved result exists for this research family; nothing was replaced or calculated.") }
            try await verifyFiles(expectedFiles,family:request.family,cadURL:document.url,directory:projectDirectory,cancellation:context.cancellation)
            try checkDocument()
            active = try sessions.openSaved(request.family,data:archive,expectedFingerprint:active.fingerprint)
        case .configure:
            guard let input = request.inputJSON else { throw FloeError.validationFailed("research.configure needs the full typed inputJSON from inspection with the same program id.") }
            try checkDocument()
            try await verifyFiles(expectedFiles,family:request.family,cadURL:document.url,directory:projectDirectory,cancellation:context.cancellation)
            try checkDocument()
            active = try sessions.configure(request.family,inputJSON:Data(input.utf8),expectedFingerprint:active.fingerprint)
            configurationSaved = true
        case .calculate:
            guard active.state != "none" else { throw FloeError.validationFailed("Open or explicitly configure this research program first; no demo is substituted for the CAD original.") }
            try await verifyFiles(expectedFiles,family:request.family,cadURL:document.url,directory:projectDirectory,cancellation:context.cancellation)
            try checkDocument()
            active = try sessions.persistConfiguration(request.family,expectedFingerprint:active.fingerprint)
            configurationSaved = true
            let computeFiles = try await savedFiles(family:request.family,cadURL:document.url,projectDirectory:projectDirectory,cancellation:context.cancellation)
            guard computeFiles.archiveSHA256 == expectedFiles.archiveSHA256,computeFiles.draftSHA256 == active.inputSHA256,
                  try sessions.snapshot(request.family).fingerprint == active.fingerprint else { throw ManufacturingError.stale }
            try checkDocument()
            let fingerprint = active.fingerprint
            let work = Task { @MainActor in
                try await sessions.calculateAndSave(request.family,expectedFingerprint:fingerprint) {
                    try checkDocument();try await validateSource()
                    try await verifyFiles(computeFiles,family:request.family,cadURL:document.url,directory:projectDirectory,cancellation:context.cancellation)
                    try checkDocument()
                }
            }
            let monitor = Task {
                while !Task.isCancelled {
                    if context.cancellation.isCancelled { work.cancel();return }
                    do { try await Task.sleep(for:.milliseconds(150)) } catch { return }
                }
            }
            defer { monitor.cancel() }
            active = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
            resultSaved = true
        case .cancel:
            guard let operationID = request.operationID else { throw FloeError.validationFailed("research.cancel needs the exact operationID from current research.status.") }
            active = try sessions.cancel(request.family,expectedFingerprint:active.fingerprint,operationID:operationID)
        case .save:
            try await verifyFiles(expectedFiles,family:request.family,cadURL:document.url,directory:projectDirectory,cancellation:context.cancellation)
            try checkDocument()
            active = try sessions.persistConfiguration(request.family,expectedFingerprint:active.fingerprint)
            configurationSaved = true
            let savingFiles = try await savedFiles(family:request.family,cadURL:document.url,projectDirectory:projectDirectory,cancellation:context.cancellation)
            guard savingFiles.archiveSHA256 == expectedFiles.archiveSHA256,savingFiles.draftSHA256 == active.inputSHA256,
                  try sessions.snapshot(request.family).fingerprint == active.fingerprint else { throw ManufacturingError.stale }
            try checkDocument()
            active = try sessions.save(request.family,expectedFingerprint:active.fingerprint);resultSaved = true
        }
        try checkDocument();try await validateSource()
        files = try await savedFiles(family:request.family,cadURL:document.url,projectDirectory:projectDirectory,cancellation:context.cancellation)
        try checkDocument()
        let selected = request.content ?? "input"
        active = try sessions.snapshot(request.family,content:selected == "result" ? "result":"input",
            offset:["input","result"].contains(selected) ? (request.offset ?? 0):0,limit:request.limit ?? 12_000)
        if resultSaved {
            guard files.archive != nil,files.inputSHA256 == active.inputSHA256,active.hasResult else { throw ManufacturingError.stale }
        }
        return try response(action:action,request:request,ownerID:ownerID,active:active,files:files,
            configurationSaved:configurationSaved,resultSaved:resultSaved)
    }
    private static func response(action:Action,request:Request,ownerID:UUID,active:ManufacturingResearchSessions.Snapshot,
                                 files:SavedFiles,configurationSaved:Bool,resultSaved:Bool) throws -> Data {
        let kind = request.content ?? "input",bytes:Data?
        let current = active.withoutContent()
        if kind == "savedInput" { bytes = files.input }
        else if kind == "savedResult" { bytes = files.result }
        else { bytes = nil }
        let text:String?,next:Int?,total:Int
        if kind == "input" || kind == "result" {
            text = action == .status ? nil:active.contentJSON
            next = action == .status ? nil:active.nextOffset;total = active.totalCharacters
        } else if let bytes {
            let source = String(decoding:bytes,as:UTF8.self),offset = request.offset ?? 0,limit = request.limit ?? 12_000
            guard offset <= source.count else { throw ManufacturingError.invalid("Saved research page offset exceeds its content") }
            let start = source.index(source.startIndex,offsetBy:offset),length = min(limit,source.count-offset),end = source.index(start,offsetBy:length)
            text = String(source[start..<end]);next = end == source.endIndex ? nil:offset+length;total = source.count
        } else { text = nil;next = nil;total = 0 }
        let saved = Saved(status:files.archive == nil ? "none":"saved",archiveSHA256:files.archiveSHA256,archiveByteCount:files.archive?.count ?? 0,
            draftSHA256:files.draftSHA256,savedInputSHA256:files.inputSHA256,savedInputMatchesActive:files.inputSHA256 != nil && files.inputSHA256 == active.inputSHA256,
            sourceRelation:"Storage ownership does not prove this independent program uses the current CAD geometry; retain its authored source.")
        let value = Response(ownerCADProjectID:ownerID,action:action,family:request.family,
            fingerprint:try fingerprint(ownerID,request.family,active,files),active:current,saved:saved,contentKind:kind,
            contentJSON:text,nextOffset:next,totalCharacters:total,configurationSaved:configurationSaved,resultSaved:resultSaved,actions:Action.allCases.map(\.rawValue))
        let data = try StudioToolOutput.data(value)
        guard data.count <= 90 * 1_024 else { throw FloeError.validationFailed("Read a smaller research page.") }
        return data
    }
    private static func fingerprint(_ owner:UUID,_ family:ManufacturingResearchFamily,_ active:ManufacturingResearchSessions.Snapshot,_ files:SavedFiles) throws -> String {
        try ResearchArchive.digest(Fingerprint(owner:owner,family:family,active:active.fingerprint,archive:files.archiveSHA256,draft:files.draftSHA256))
    }
    private nonisolated static func inputDigest(_ data:Data,family:ManufacturingResearchFamily) throws -> String {
        try ManufacturingResearchSessions.inputFingerprint(data,family:family)
    }
    private static func savedFiles(family:ManufacturingResearchFamily,cadURL:URL,projectDirectory:URL,cancellation:CancellationToken) async throws -> SavedFiles {
        let work = Task.detached(priority:.utility) {
            try CADSavedManufacturingResearchReader.withData(family:family,cadURL:cadURL,projectDirectory:projectDirectory,cancellation:cancellation) { archive in
                try CADSavedManufacturingResearchReader.withData(family:family,isDraft:true,cadURL:cadURL,projectDirectory:projectDirectory,cancellation:cancellation) { draft in
                    var value = SavedFiles(archive:archive,draft:draft)
                    value.archiveSHA256 = archive.map(ManufacturingStudy.digest);value.draftSHA256 = draft.map(ManufacturingStudy.digest)
                    if let draft { _ = try inputDigest(draft,family:family) }
                    if let archive {
                        switch family {
                        case .manufacturingCell:
                            let (project,artifact) = try ManufacturingCellArchive.open(data:archive)
                            value.input = try ManufacturingStudy.encoder.encode(project);value.result = try ManufacturingStudy.encoder.encode(artifact);value.inputSHA256 = artifact.inputSHA256
                        case .virtualMachine:
                            let (project,artifact) = try ResearchArchive.open(data:archive,input:VirtualMachineProject.self,output:VirtualMachineArtifact.self,family:.virtualMachine) { try $1.validate(for:$0) }
                            value.input = try ManufacturingStudy.encoder.encode(project);value.result = try ManufacturingStudy.encoder.encode(artifact);value.inputSHA256 = artifact.inputSHA256
                        case .engineeringAnalysis:
                            let (project,artifact) = try ResearchArchive.open(data:archive,input:EngineeringAnalysisProject.self,output:EngineeringAnalysisArtifact.self,family:.engineeringAnalysis) { try $1.validate(for:$0) }
                            value.input = try ManufacturingStudy.encoder.encode(project);value.result = try ManufacturingStudy.encoder.encode(artifact);value.inputSHA256 = artifact.inputSHA256
                        }
                    }
                    return value
                }
            }
        }
        return try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
    }
    private static func verifyFiles(_ expected:SavedFiles,family:ManufacturingResearchFamily,cadURL:URL,directory:URL,cancellation:CancellationToken) async throws {
        let work = Task.detached(priority:.utility) {
            try CADSavedManufacturingResearchReader.withData(family:family,cadURL:cadURL,projectDirectory:directory,cancellation:cancellation) { archive in
                try CADSavedManufacturingResearchReader.withData(family:family,isDraft:true,cadURL:cadURL,projectDirectory:directory,cancellation:cancellation) { draft in
                    guard archive.map(ManufacturingStudy.digest) == expected.archiveSHA256,draft.map(ManufacturingStudy.digest) == expected.draftSHA256 else { throw ManufacturingError.stale }
                }
            }
        }
        try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
    }
}
#endif

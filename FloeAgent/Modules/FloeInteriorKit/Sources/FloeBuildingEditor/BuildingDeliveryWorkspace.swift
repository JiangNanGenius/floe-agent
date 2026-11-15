// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import Observation
import FloeBuildingCAD
import FloeBuildingRecords

public struct BuildingEditorDrawingPageOption:Identifiable,Equatable,Sendable {
    public let id:UUID
    public let title:String
}

struct BuildingDeliveryRecord:Identifiable,Sendable {
    let id:UUID
    let directory:URL
    let receipt:FloeBuildingCADDeliveryReceipt
    func fileURL(_ file:FloeBuildingCADExportFile) -> URL? {
        let parts=file.relativePath.split(separator:"/",omittingEmptySubsequences:false)
        guard !parts.isEmpty,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")}) else{return nil}
        let url=directory.appendingPathComponent(file.relativePath).standardizedFileURL
        let root=directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolved=url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard resolved.count>root.count,Array(resolved.prefix(root.count))==root,
              FileManager.default.fileExists(atPath:url.path) else{return nil}
        return url
    }
}

/// Long-running output work belongs to the project, not to a drawing page's
/// lifetime. Generated bundles live under CAD/Deliverables so the next project
/// checkpoint includes them with the source generation and original receipts.
@MainActor @Observable
final class BuildingDeliveryWorkspace {
    enum Activity:Equatable {case idle,loading,generating,exporting,registering}
    typealias Generate=@MainActor (UUID) async throws->Void
    typealias Export=@MainActor (UUID) async throws->(URL,FloeBuildingCADDeliveryReceipt)
    typealias ExportProject=@MainActor (UUID?) async throws->(URL,FloeBuildingCADDeliveryReceipt)
    typealias Pages=@MainActor () throws->[BuildingEditorDrawingPageOption]
    let directory:URL
    private let generate:Generate
    private let export:Export
    private let pages:Pages
    private let exportProject:ExportProject
    var selectedCabinetID:UUID?
    var selectedProjectPageID:UUID?
    var projectPages:[BuildingEditorDrawingPageOption]=[]
    var records:[BuildingDeliveryRecord]=[]
    var activity:Activity = .idle
    var errorDetails:String?
    private(set) var failureActivity:Activity?
    var generatedCabinetID:UUID?
    private(set) var registeredFiles: Set<String> = []
    private var task:Task<Void,Never>?
    private var operationID:UUID?
    private var closed=false
    var busy:Bool {activity != .idle}

    init(directory:URL,generate:@escaping Generate,export:@escaping Export,pages:@escaping Pages,exportProject:@escaping ExportProject) {
        self.directory=directory;self.generate=generate;self.export=export;self.pages=pages;self.exportProject=exportProject
    }
    private func launch(_ next:Activity,work:@escaping @MainActor () async throws->Void) {
        guard !closed,!busy else{return}
        let id=UUID();operationID=id;activity=next;errorDetails=nil;failureActivity=nil;generatedCabinetID=nil
        task=Task {@MainActor in
            defer {if operationID==id {operationID=nil;activity = .idle;task=nil}}
            do {try await work()}
            catch {if !closed,operationID==id,!Task.isCancelled {failureActivity=next;errorDetails=error.localizedDescription}}
        }
    }
    func reload() {
        launch(.loading) {
            let directory=self.directory
            let scan=Task.detached{try Self.readRecords(directory)}
            let rows=try await withTaskCancellationHandler {try await scan.value} onCancel:{scan.cancel()}
            try Task.checkCancellation();guard !self.closed else{return};self.records=rows
            self.projectPages=try self.pages()
            if let chosen=self.selectedProjectPageID,!self.projectPages.contains(where:{$0.id==chosen}) {self.selectedProjectPageID=nil}
        }
    }
    func makeSheets() {
        guard let selectedCabinetID else{return}
        launch(.generating) {
            try await self.generate(selectedCabinetID)
            try Task.checkCancellation();guard !self.closed else{return}
            self.projectPages=try self.pages()
            self.generatedCabinetID=selectedCabinetID
        }
    }
    func exportSelected() {
        guard let selectedCabinetID else{return}
        launch(.exporting) {
            let (directory,receipt)=try await self.export(selectedCabinetID)
            try Task.checkCancellation();guard !self.closed,let id=UUID(uuidString:directory.lastPathComponent) else{return}
            self.records.insert(.init(id:id,directory:directory,receipt:receipt),at:0)
        }
    }
    func exportWholeProject(includeSelectedPage:Bool) {
        let page=includeSelectedPage ? selectedProjectPageID:nil
        if includeSelectedPage && page==nil{return}
        launch(.exporting) {
            let (directory,receipt)=try await self.exportProject(page)
            try Task.checkCancellation();guard !self.closed,let id=UUID(uuidString:directory.lastPathComponent) else{return}
            self.records.insert(.init(id:id,directory:directory,receipt:receipt),at:0)
        }
    }
    func registerIndependentProject(record:BuildingDeliveryRecord,file:FloeBuildingCADExportFile,
                                    projectID:ProjectID,
                                    using handler:@escaping @MainActor (BuildingIndependentCADHandoff) async throws->Void) {
        let key=record.id.uuidString+"/"+file.relativePath
        guard !registeredFiles.contains(key) else{return}
        launch(.registering) {
            let request=try await BuildingIndependentCADHandoff.prepare(record:record,file:file,projectID:projectID)
            try Task.checkCancellation();guard !self.closed else{return}
            try await handler(request)
            try Task.checkCancellation();guard !self.closed else{return}
            self.registeredFiles.insert(key)
        }
    }
    func isRegistered(record:BuildingDeliveryRecord,file:FloeBuildingCADExportFile)->Bool {
        registeredFiles.contains(record.id.uuidString+"/"+file.relativePath)
    }
    func cancel() {task?.cancel()}
    func waitForIdle() async {let owned=task;await owned?.value}
    func stop() async {
        closed=true;task?.cancel();let owned=task;await owned?.value
        task=nil;operationID=nil;activity = .idle
    }
    nonisolated private static func readRecords(_ directory:URL) throws->[BuildingDeliveryRecord] {
        guard FileManager.default.fileExists(atPath:directory.path) else{return []}
        let directories=try FileManager.default.contentsOfDirectory(at:directory,
            includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])
        guard directories.count<=512 else{throw BuildingProjectStateError.budget}
        var records:[BuildingDeliveryRecord]=[]
        for folder in directories {
            try Task.checkCancellation()
            guard let id=UUID(uuidString:folder.lastPathComponent) else{continue}
            let properties=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard properties.isDirectory==true,properties.isSymbolicLink != true else{throw BuildingProjectStateError.identityOrSchema}
            let url=folder.appendingPathComponent("receipt.json")
            let file=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard file.isRegularFile==true,file.isSymbolicLink != true,let bytes=file.fileSize,bytes<=1024*1024 else {
                throw BuildingProjectStateError.budget
            }
            let receipt=try JSONDecoder().decode(FloeBuildingCADDeliveryReceipt.self,from:Data(contentsOf:url))
            guard receipt.schemaVersion==1,receipt.files.count<=128 else{throw BuildingProjectStateError.identityOrSchema}
            let record=BuildingDeliveryRecord(id:id,directory:folder,receipt:receipt)
            guard receipt.files.allSatisfy({record.fileURL($0) != nil}) else{throw BuildingProjectStateError.identityOrSchema}
            records.append(record)
        }
        return records.sorted{$0.receipt.createdAtISO8601 > $1.receipt.createdAtISO8601}
    }
}
#endif

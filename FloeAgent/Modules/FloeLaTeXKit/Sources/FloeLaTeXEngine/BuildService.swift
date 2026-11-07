// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

/// App-owned, independent of editor lifetime. A cancelled build keeps its lease
/// until the engine has actually stopped, then releases its immutable source.
public actor LaTeXBuildService {
    public nonisolated let cacheRoot:URL
    private let engine:any LaTeXEngineRunning
    private struct Running {var projectID:UUID;var root:URL;var record:LaTeXBuildRecord;var task:Task<LaTeXBuildRecord,Never>;var lifetime:(any LaTeXBuildLifetime)?}
    private var running=[UUID:Running]()
    private var records=[UUID:LaTeXBuildRecord]()
    private struct Retained {var store:LaTeXProjectStore;var snapshot:LaTeXProjectSnapshot;var lifetime:(any LaTeXBuildLifetime)?}
    private var unconfirmed=[UUID:Retained]()
    private var preparing=Set<UUID>()
    public init(cacheRoot:URL,engine:any LaTeXEngineRunning = LaTeXEngineRouter()) throws {
        self.cacheRoot=cacheRoot;self.engine=engine
        try FileManager.default.createDirectory(at:cacheRoot,withIntermediateDirectories:true)
    }
    public func capabilities() async -> [LaTeXEngineCapability] {await engine.capabilities()}
    public func start(store:LaTeXProjectStore,expectedRevision:Int64? = nil,configuration:LaTeXBuildConfiguration = .init(),executionOwner:LaTeXExecutionOwner?=nil,lifetime:(any LaTeXBuildLifetime)?=nil,engineOverride:(any LaTeXEngineRunning)?=nil) async throws -> LaTeXBuildRecord {
        let manifest=try await store.manifest()
        _=try history(store:store)
        guard !unconfirmed.values.contains(where:{$0.snapshot.manifest.id==manifest.id}) else {throw LaTeXError.unavailable("The previous environment worker must be reconciled before this project can run again.")}
        if let expectedRevision,manifest.revision != expectedRevision {throw LaTeXError.revisionConflict(expected:expectedRevision,actual:manifest.revision)}
        if let existing=running.values.first(where:{$0.projectID == manifest.id}) {
            guard existing.record.revision == manifest.revision,existing.record.executionOwner==executionOwner else {throw LaTeXError.invalidOperation("A build is already running for this project. Inspect or stop it before starting another.")}
            return existing.record
        }
        guard preparing.insert(manifest.id).inserted else {throw LaTeXError.unavailable("This project is already preparing a build.")}
        defer {preparing.remove(manifest.id)}
        let snapshot=try await store.snapshot(expectedRevision:manifest.revision)
        var record=LaTeXBuildRecord(snapshot:snapshot);record.executionOwner=executionOwner
        let directory=store.root.appendingPathComponent("Builds/"+record.id.uuidString,isDirectory:true)
        do {try persist(record,root:store.root);try LaTeXDigest.encode(snapshot.manifest).write(to:directory.appendingPathComponent("SourceManifest.json"),options:.atomic)} catch {try? await store.releaseSnapshot(snapshot);throw error}
        let selectedEngine=engineOverride ?? engine
        let task=Task { await self.execute(record:record,snapshot:snapshot,store:store,directory:directory,configuration:configuration,selectedEngine:selectedEngine) }
        running[record.id] = .init(projectID:manifest.id,root:store.root,record:record,task:task,lifetime:lifetime)
        records[record.id]=record
        return record
    }
    public func cancel(_ id:UUID) {running[id]?.task.cancel()}
    public func cancel(projectID:UUID) {for run in running.values where run.projectID == projectID {run.task.cancel()}}
    public func wait(_ id:UUID) async throws -> LaTeXBuildRecord {
        if let run=running[id] {
            return await withTaskCancellationHandler {await run.task.value} onCancel:{Task {await self.cancel(id)}}
        }
        guard let record=records[id] else {throw LaTeXError.missingFile("build")};return record
    }
    public func record(_ id:UUID) -> LaTeXBuildRecord? {records[id]}
    public func history(store:LaTeXProjectStore) throws -> [LaTeXBuildRecord] {
        let root=store.root.appendingPathComponent("Builds")
        guard FileManager.default.fileExists(atPath:root.path) else {return []}
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey])
            .filter {(try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true}
            .compactMap {directory -> LaTeXBuildRecord? in
                guard let data=try? Data(contentsOf:directory.appendingPathComponent("Build.json")),var record=try? JSONDecoder().decode(LaTeXBuildRecord.self,from:data) else {return nil}
                if let active=records[record.id] {return active}
                if record.isActive {
                    record.state = .interrupted;record.finishedAt=Date()
                    // A process restart proves nothing about an independent
                    // guest/SSH worker. Retain its exact snapshot until the
                    // host reconciles that existing execution job.
                    if record.executionOwner?.environmentID != nil {record.workerStopped=false}
                    record.diagnostics.append(.init(severity:.warning,message:"This build was interrupted. Your source was preserved."));try persist(record,root:store.root)
                }
                if record.workerStopped==false,unconfirmed[record.id]==nil {
                    let url=directory.appendingPathComponent("SourceManifest.json")
                    guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=16*1024*1024 else {throw LaTeXError.limitExceeded("build snapshot")}
                    let manifest=try JSONDecoder().decode(LaTeXProjectManifest.self,from:Data(contentsOf:url))
                    guard manifest.id==record.projectID,manifest.revision==record.revision else {throw LaTeXError.invalidProject}
                    let snapshot=LaTeXProjectSnapshot(id:record.snapshotID,manifest:manifest,sourceRoot:store.root.appendingPathComponent("Snapshots/"+record.snapshotID.uuidString),fingerprint:record.fingerprint)
                    unconfirmed[record.id] = .init(store:store,snapshot:snapshot,lifetime:nil)
                }
                records[record.id]=record;return record
            }.sorted {$0.startedAt>$1.startedAt}
    }
    public func isBusy(projectID:UUID)->Bool {preparing.contains(projectID) || running.values.contains {$0.projectID==projectID} || unconfirmed.values.contains{$0.snapshot.manifest.id==projectID}}
    /// Host-only lifecycle acknowledgement after the existing jobs service has
    /// proved its exact worker terminal. Never expose this as a model boolean.
    public func releaseAfterConfirmedWorkerStop(_ buildID:UUID) async throws {
        guard let retained=unconfirmed[buildID] else {return}
        try await retained.store.releaseSnapshot(retained.snapshot)
        if var record=records[buildID] {record.workerStopped=true;try persist(record,root:retained.store.root);records[buildID]=record}
        unconfirmed.removeValue(forKey:buildID)
    }
    private func persist(_ record:LaTeXBuildRecord,root:URL) throws {
        let directory=root.appendingPathComponent("Builds/"+record.id.uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try LaTeXDigest.encode(record).write(to:directory.appendingPathComponent("Build.json"),options:.atomic)
    }
    private func progress(_ message:String,id:UUID) {
        guard var value=records[id],value.isActive else {return}
        if value.messages.count<4096 {value.messages.append(String(message.prefix(8192)))}
        records[id]=value;running[id]?.record=value
    }
    private func execute(record:LaTeXBuildRecord,snapshot:LaTeXProjectSnapshot,store:LaTeXProjectStore,directory:URL,configuration:LaTeXBuildConfiguration,selectedEngine:any LaTeXEngineRunning) async -> LaTeXBuildRecord {
        var result=record
        var stopped=true
        do {
            try Task.checkCancellation()
            result.state = .compiling;records[result.id]=result;running[result.id]?.record=result;try persist(result,root:store.root)
            let request=LaTeXEngineRequest(snapshot:snapshot,outputRoot:directory.appendingPathComponent("Output"),cacheRoot:cacheRoot,configuration:configuration,executionOwner:record.executionOwner,buildDate:record.startedAt)
            let output=try await selectedEngine.run(request) {message in Task {await self.progress(message,id:record.id)}}
            try Task.checkCancellation()
            let canonical=output.pdf.standardizedFileURL.resolvingSymlinksInPath()
            let outputRoot=request.outputRoot.standardizedFileURL.resolvingSymlinksInPath().path+"/"
            guard canonical.path.hasPrefix(outputRoot),(try canonical.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 256*1024*1024 else {throw LaTeXError.invalidPath(output.pdf.path)}
            let handle=try FileHandle(forReadingFrom:canonical);defer {try? handle.close()}
            guard try handle.read(upToCount:5) == Data("%PDF-".utf8) else {throw LaTeXError.invalidOperation("The engine produced an invalid PDF.")}
            result.state = .succeeded;result.engineVersion=output.version;result.bundleDigest=output.bundleDigest
            result.pdfRelativePath="Output/"+String(canonical.path.dropFirst(outputRoot.count))
            let sync=canonical.deletingPathExtension().appendingPathExtension("synctex.gz")
            if FileManager.default.fileExists(atPath:sync.path) {result.synctexRelativePath="Output/"+String(sync.path.dropFirst(outputRoot.count))}
            result.messages=Array(output.messages.prefix(4096))
        } catch {
            let failure=error as? LaTeXEngineFailure
            stopped=failure?.workerStopped ?? true
            result.state = Task.isCancelled || error is CancellationError || failure?.cancelled == true ? .cancelled : .failed
            if !stopped {result.state = .interrupted}
            result.messages=failure?.messages ?? records[result.id]?.messages ?? []
            result.diagnostics.append(.init(severity:result.state == .cancelled ? .information : .error,message:error.localizedDescription,path:snapshot.manifest.mainFile))
        }
        let originalLog=directory.appendingPathComponent("Output").appendingPathComponent(snapshot.manifest.mainFile).deletingPathExtension().appendingPathExtension("log")
        let standardLog=directory.appendingPathComponent("Output/document.log")
        let log=FileManager.default.fileExists(atPath:originalLog.path) ? originalLog:standardLog
        if let size=try? log.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<16*1024*1024,let data=try? Data(contentsOf:log) {
            result.diagnostics+=LaTeXLogParser.diagnostics(String(decoding:data,as:UTF8.self),defaultPath:snapshot.manifest.mainFile)
        } else {result.diagnostics+=LaTeXLogParser.diagnostics(result.messages.joined(separator:"\n"),defaultPath:snapshot.manifest.mainFile)}
        result.finishedAt=Date()
        result.workerStopped=stopped
        do {try persist(result,root:store.root)} catch {result.diagnostics.append(.init(severity:.error,message:"The build result could not be saved: "+error.localizedDescription))}
        // Always await actual engine completion before releasing source and project ownership.
        if stopped {try? await store.releaseSnapshot(snapshot)}
        else {unconfirmed[result.id] = .init(store:store,snapshot:snapshot,lifetime:running[result.id]?.lifetime)}
        records[result.id]=result;running.removeValue(forKey:result.id)
        return result
    }
}

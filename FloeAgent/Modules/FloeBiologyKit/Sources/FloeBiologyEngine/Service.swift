// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public enum BiologyAccessAction: String, Sendable { case list, create, read, edit, compute, export, delete, restore }
public struct BiologyAccess: Sendable {
    public var action: BiologyAccessAction
    public var projectID: UUID?
    public init(action:BiologyAccessAction,projectID:UUID? = nil) { self.action=action;self.projectID=projectID }
}

/// One service owns the project's calculations across views. The host supplies
/// its existing authorization and environment transports at integration time.
public actor BiologyService {
    public let store: BiologyProjectStore
    let authorize: @Sendable (BiologyAccess) async throws -> Void
    var backends: [String:any BiologyBackend]
    var workers: [UUID:Task<Void,Never>] = [:]
    var pendingStarts=0
    var pendingEnvironments:[String:Int]=[:]
    var runningEnvironments:[UUID:String]=[:]
    var exportWorkers:[String:(identity:BiologyMutationIdentity,task:Task<BiologyExportReceipt,Error>)]=[:]
    var observers:[UUID:[UUID:AsyncStream<UInt64>.Continuation]]=[:]
    let fileAccess:(any BiologyFileAccessing)?
    public init(store:BiologyProjectStore,backends:[any BiologyBackend] = [NativeBiologyBackend()],fileAccess:(any BiologyFileAccessing)? = nil,authorize:@escaping @Sendable (BiologyAccess) async throws -> Void) throws {
        guard Set(backends.map(\.environmentID)).count==backends.count else { throw BiologyError.invalid("Duplicate backend environment identifiers.") }
        self.store=store;self.backends=Dictionary(uniqueKeysWithValues:backends.map{($0.environmentID,$0)});self.authorize=authorize;self.fileAccess=fileAccess
    }
    func permit(_ action:BiologyAccessAction,_ id:UUID? = nil) async throws { try await authorize(.init(action:action,projectID:id)) }
    func changed(_ id:UUID) {for continuation in observers[id]?.values ?? Dictionary<UUID,AsyncStream<UInt64>.Continuation>().values {continuation.yield(0)}}
    public func changes(_ id:UUID) async throws -> AsyncStream<UInt64> {
        try await permit(.read,id)
        let token=UUID()
        let (stream,continuation)=AsyncStream<UInt64>.makeStream(bufferingPolicy:.bufferingNewest(1))
        observers[id,default:[:]][token]=continuation;continuation.yield(0)
        continuation.onTermination={ [weak self] _ in Task{await self?.removeObserver(id,token:token)}}
        return stream
    }
    private func removeObserver(_ id:UUID,token:UUID) {observers[id]?.removeValue(forKey:token);if observers[id]?.isEmpty==true {observers.removeValue(forKey:id)}}
    /// Trusted host configuration after probing an actual resolved environment.
    /// Existing workers retain their backend until completion.
    public func configureBackend(_ backend:any BiologyBackend) throws {
        guard backend.environmentID != "native.local",!backend.environmentID.isEmpty,!backend.methods.isEmpty,backend.methods.count<=256 else {throw BiologyError.invalid("Invalid scientific backend configuration.")}
        if let old=backends[backend.environmentID],old.engineVersion==backend.engineVersion,old.methods==backend.methods{return}
        guard !runningEnvironments.values.contains(backend.environmentID),(pendingEnvironments[backend.environmentID] ?? 0)==0 else {throw BiologyError.unavailable("Wait for this environment's active calculations before changing its engines.")}
        backends[backend.environmentID]=backend
    }
    public func capabilities(kind:BiologyAssetKind? = nil) -> [String:[String]] {
        backends.mapValues { backend in backend.methods.filter { kind == nil || Self.methodKind($0)==kind }.sorted() }
    }
    public func capabilities(for asset:BiologyAsset) -> [String:[String]] {
        backends.mapValues{$0.methods.filter{Self.acceptsMethod($0,for:asset)}.sorted()}
    }
    /// Offered methods are schema candidates, not evidence of installed
    /// engines. The selected task's real probe still runs on Execute.
    public nonisolated static func optionalScientificMethods(for asset:BiologyAsset) -> [String] {
        BiologyEditCatalog.scientificMethods.filter{acceptsMethod($0,for:asset)}.sorted()
    }
    private nonisolated static func acceptsMethod(_ method:String,for asset:BiologyAsset) -> Bool {
        guard asset.kind == .externalDataset else{return methodKind(method)==asset.kind}
        let allowed:Set<String>
        switch asset.originalFormat {
        case "h5ad","mtx":allowed=Set(["omics.import","omics.qc","omics.normalize","omics.pca","omics.cluster","omics.embedding","omics.diffexp","omics.export"])
        case "sbml","xml":allowed=["net.sbml.import","net.sbml.simulate","net.sbml.sweep"]
        case "tif","tiff":allowed=["micro.import","micro.segment","micro.overlay","micro.series","micro.tile"]
        case "newick","nwk","tree":allowed=["tree.inspect"]
        case "mrc","map","ccp4":allowed=asset.fileReference==nil ? ["volume.statistics","volume.slice","volume.isosurface"]:[]
        default:allowed=[]
        }
        return allowed.contains(method)
    }
    public nonisolated static func methodKind(_ method:String) -> BiologyAssetKind? {
        switch method.components(separatedBy:".").first {
        case "sequence","seq":.sequence
        case "structure","struct":.proteinStructure
        case "image","micro":.microscopyImage
        case "matrix","omics":.expressionMatrix
        case "network","net":.biochemicalNetwork
        case "tree","volume":.externalDataset
        default:nil
        }
    }
    public func projects() async throws -> [BiologyProject] { try await permit(.list);return try await store.list() }
    public func create(title:String,identity:BiologyMutationIdentity? = nil) async throws -> BiologyProject { try await permit(.create);return try await store.create(title:title,identity:identity) }
    /// Native host reservations are not a model/tool argument. The ordinary
    /// tool create path retains its deterministic operation identity unchanged.
    public func createBound(id:UUID,title:String) async throws -> BiologyProject { try await permit(.create);return try await store.createBound(id:id,title:title) }
    public func project(_ id:UUID) async throws -> BiologyProject { try await permit(.read,id);return try await store.load(id) }
    public func rename(_ id:UUID,title:String,expectedRevision:UInt64) async throws {
        try await permit(.edit,id);_=try await store.update(id,expectedRevision:expectedRevision){$0.title=title}
        changed(id)
    }
    public func saveNotes(_ id:UUID,text:String,expectedRevision:UInt64) async throws {
        try await permit(.edit,id);_=try await store.update(id,expectedRevision:expectedRevision){$0.notes=text}
        changed(id)
    }
    public func linkChemistry(_ id:UUID,reference:String,expectedRevision:UInt64) async throws {
        try await permit(.edit,id)
        guard reference.hasPrefix("floe-chemistry:"),reference.utf8.count<=4096 else { throw BiologyError.invalid("Choose an explicit chemistry project/object reference.") }
        _=try await store.update(id,expectedRevision:expectedRevision){if !$0.chemistryLinks.contains(reference){$0.chemistryLinks.append(reference)}}
        changed(id)
    }
    @discardableResult public func importAsset(_ id:UUID,title:String,format:String,data:Data,provenance:[String:String] = [:],identity:BiologyMutationIdentity? = nil) async throws -> BiologyAsset {
        try await permit(.edit,id)
        var asset=try await Task.detached { try BiologyImporter.parse(title:title,format:format,data:data) }.value
        asset.provenance=provenance
        let saved=asset
        try await permit(.edit,id)
        let assetID=try await store.transact(id,identity:identity){p in p.assets.append(saved);return saved.id}
        guard let result=try await store.load(id).assets.first(where:{$0.id==assetID}) else {throw BiologyError.invalid("The imported dataset was subsequently removed.")}
        changed(id);return result
    }
    public func replacePayload(_ id:UUID,assetID:UUID,expectedAssetRevision:UInt64,payload:BiologyAssetPayload) async throws {
        try await permit(.edit,id)
        _=try await store.update(id) { project in
            guard let i=project.assets.firstIndex(where:{$0.id==assetID}) else { throw BiologyError.invalid("Dataset no longer exists.") }
            guard project.assets[i].revision==expectedAssetRevision else { throw BiologyError.conflict(expected:expectedAssetRevision,actual:project.assets[i].revision) }
            guard project.assets[i].kind==payload.kind,expectedAssetRevision<UInt64.max else { throw BiologyError.invalid("Dataset kind or revision changed.") }
            project.assets[i].payload=payload;project.assets[i].revision+=1
            project.selections?.removeValue(forKey:assetID.uuidString)
        }
        changed(id)
    }
    public func editSequence(_ id:UUID,assetID:UUID,expectedAssetRevision:UInt64,record:Int,start:Int,end:Int,replacement:String,identity:BiologyMutationIdentity? = nil) async throws {
        try await permit(.edit,id)
        let replacement=replacement.uppercased().filter{!$0.isWhitespace}
        guard replacement.isEmpty || (try? BiologyImporter.validateSequence(replacement)) != nil else { throw BiologyError.invalid("Invalid replacement sequence.") }
        let _:UUID=try await store.transact(id,identity:identity) { p in
            guard let i=p.assets.firstIndex(where:{$0.id==assetID}),case .sequence(var records)=p.assets[i].payload,records.indices.contains(record) else { throw BiologyError.invalid("Select a sequence record.") }
            guard p.assets[i].revision==expectedAssetRevision,expectedAssetRevision<UInt64.max else { throw BiologyError.conflict(expected:expectedAssetRevision,actual:p.assets[i].revision) }
            let count=records[record].sequence.count
            guard start>=0,end>=start,end<=count else { throw BiologyError.invalid("Invalid half-open sequence range.") }
            let s=records[record].sequence
            let lo=s.index(s.startIndex,offsetBy:start),hi=s.index(s.startIndex,offsetBy:end)
            let changed=String(s[..<lo])+replacement+String(s[hi...])
            try BiologyImporter.validateSequence(changed)
            let delta=replacement.count-(end-start)
            var invalidated=0
            records[record].annotations=records[record].annotations.compactMap { a in
                if a.end<=start { return a }
                if a.start>=end { var shifted=a;shifted.start+=delta;shifted.end+=delta;return shifted }
                invalidated+=1;return nil
            }
            records[record].sequence=changed
            if records[record].quality != nil { records[record].quality=nil;p.assets[i].warnings.append("Edited sequence has no measured quality scores. The original FASTQ is retained.") }
            if invalidated>0 { p.assets[i].warnings.append("\(invalidated) overlapping annotations were invalidated by the edit; original annotations remain in the source file.") }
            p.assets[i].payload = .sequence(records);p.assets[i].revision+=1
            p.selections?.removeValue(forKey:assetID.uuidString)
            return assetID
        }
        changed(id)
    }
    public func history(_ id:UUID) async throws -> [UInt64] { try await permit(.read,id);return try await store.history(id) }
    public func restore(_ id:UUID,revision:UInt64,expectedRevision:UInt64,identity:BiologyMutationIdentity? = nil) async throws -> BiologyProject {
        try await permit(.restore,id)
        let result=try await store.restore(id,revision:revision,expectedRevision:expectedRevision,identity:identity);changed(id);return result
    }
    public func delete(_ id:UUID,expectedRevision:UInt64? = nil,identity:BiologyMutationIdentity? = nil) async throws { try await permit(.delete,id);try await store.trash(id,expectedRevision:expectedRevision,identity:identity);changed(id) }
    public func deletedProjects() async throws -> [BiologyDeletedProject] {try await permit(.list);return try await store.deletedProjects()}
    public func restoreDeleted(_ trashID:String,projectID:UUID,identity:BiologyMutationIdentity? = nil) async throws -> BiologyProject {try await permit(.restore,projectID);let p=try await store.restoreDeleted(trashID,projectID:projectID,identity:identity);changed(projectID);return p}
    public func exportAsset(_ id:UUID,assetID:UUID,format:String) async throws -> Data {
        try await permit(.export,id)
        let p=try await store.load(id)
        guard let a=p.assets.first(where:{$0.id==assetID}) else { throw BiologyError.invalid("Dataset no longer exists.") }
        return try BiologyExport.asset(a,format:format)
    }
    public func exportProject(_ id:UUID) async throws -> Data { try await permit(.export,id);return try BiologyCoding.encode(await store.load(id)) }
    public func importProject(_ data:Data,identity:BiologyMutationIdentity? = nil) async throws -> BiologyProject {
        try await permit(.create)
        guard data.count<=BiologyProjectStore.maximumProjectBytes else { throw BiologyError.invalid("Project import exceeds its size limit.") }
        var imported=try JSONDecoder().decode(BiologyProject.self,from:data)
        guard imported.assets.allSatisfy({$0.fileReference==nil}) else {throw BiologyError.invalid("Referenced project files must be imported through authorized file services.")}
        imported.mutationReceipts=nil
        imported.createdByOperation=nil;imported.deletedAt=nil
        for i in imported.runs.indices {imported.runs[i].owner=nil}
        try BiologyProjectStore.validate(imported)
        for i in imported.runs.indices where imported.runs[i].isActive { imported.runs[i].status = .interrupted;imported.runs[i].workerStopUnconfirmed=nil;imported.runs[i].error="Imported historical run; it was not restarted." }
        return try await store.create(title:imported.title,identity:identity,contents:imported)
    }
    @discardableResult public func start(_ id:UUID,assetID:UUID,expectedAssetRevision:UInt64,method:String,options:JSONValue = .object([:]),environmentID:String = "native.local",owner:BiologyExecutionOwner? = nil,identity:BiologyMutationIdentity? = nil,cancellationCheck:(@Sendable ()->Bool)?=nil) async throws -> BiologyRun {
        try await permit(.compute,id)
        try BiologyMethodCatalog.validate(options,method:method)
        if let identity,let bytes=try await store.receipt(id,identity:identity) {
            let accepted=try JSONDecoder().decode(BiologyRun.self,from:bytes)
            return try await store.load(id).runs.first(where:{$0.id==accepted.id}) ?? accepted
        }
        guard let backend=backends[environmentID],backend.methods.contains(method) else { throw BiologyError.unavailable("Choose an available method and configured execution environment.") }
        let p=try await store.load(id)
        guard let asset=p.assets.first(where:{$0.id==assetID}),asset.revision==expectedAssetRevision else { throw BiologyError.invalid("The input changed. Refresh before running this analysis.") }
        guard capabilities(for:asset)[environmentID]?.contains(method)==true else { throw BiologyError.invalid("The method does not accept this dataset format.") }
        guard workers.count+pendingStarts<8 else { throw BiologyError.unavailable("Wait for or stop an active calculation before starting another.") }
        pendingStarts+=1;pendingEnvironments[environmentID,default:0]+=1
        defer{pendingStarts-=1;pendingEnvironments[environmentID,default:0]-=1}
        let run=BiologyRun(asset:asset,inputDigest:BiologyProjectStore.digest(try BiologyCoding.encode(asset)),method:method,options:options,environmentID:environmentID,engineVersion:backend.engineVersion,owner:owner)
        let committed=try await store.transactReceipt(id,identity:identity) { current in
            guard let input=current.assets.first(where:{$0.id==asset.id}),input==asset else { throw BiologyError.invalid("The input changed before the calculation started.") }
            current.runs.append(run)
            return run
        }
        if committed.replayed {return committed.value}
        if Task.isCancelled || cancellationCheck?()==true {
            _=try await store.update(id){p in if let i=p.runs.firstIndex(where:{$0.id==run.id}){p.runs[i].status = .cancelled}}
            changed(id);var stopped=run;stopped.status = .cancelled;return stopped
        }
        do{try await backend.prepare(runID:run.id,owner:owner,requestID:identity?.requestID)}
        catch{await finish(id,runID:run.id,result:nil,error:error.localizedDescription,cancelled:Task.isCancelled || error is CancellationError);throw error}
        runningEnvironments[run.id]=environmentID
        workers[run.id]=Task.detached { [weak self] in
            await self?.markRunning(id,runID:run.id)
            do {
                try Task.checkCancellation()
                let result:BiologyAnalysisResult
                if let cancellationCheck {
                    result=try await withThrowingTaskGroup(of:BiologyAnalysisResult.self){group in
                        group.addTask{try await backend.evaluate(projectID:id,asset:asset,method:method,options:options,runID:run.id,owner:owner)}
                        group.addTask{
                            while !cancellationCheck(){try await Task.sleep(for:.milliseconds(100))}
                            try await backend.cancel(runID:run.id);throw CancellationError()
                        }
                        defer{group.cancelAll()}
                        guard let first=try await group.next() else {throw CancellationError()};return first
                    }
                }else{result=try await backend.evaluate(projectID:id,asset:asset,method:method,options:options,runID:run.id,owner:owner)}
                try Task.checkCancellation()
                await self?.finish(id,runID:run.id,result:result,error:nil,cancelled:false)
            } catch {
                await self?.finish(id,runID:run.id,result:nil,error:error.localizedDescription,cancelled:Task.isCancelled || error is CancellationError,stopUnconfirmed:error is BiologyWorkerStopUnconfirmed)
            }
        }
        changed(id);return run
    }
    private func markRunning(_ id:UUID,runID:UUID) async {
        do { _=try await store.update(id){p in if let i=p.runs.firstIndex(where:{$0.id==runID}),p.runs[i].status == .queued {p.runs[i].status = .running}} }
        catch { /* Completion retains the save failure if it can safely reconcile. */ }
        changed(id)
    }
    private func finish(_ id:UUID,runID:UUID,result:BiologyAnalysisResult?,error:String?,cancelled:Bool,stopUnconfirmed:Bool=false) async {
        defer{workers.removeValue(forKey:runID);runningEnvironments.removeValue(forKey:runID);changed(id)}
        do {
            _=try await store.update(id) { p in
                guard let i=p.runs.firstIndex(where:{$0.id==runID}),p.runs[i].isActive else { return }
                if stopUnconfirmed {p.runs[i].status = .interrupted;p.runs[i].workerStopUnconfirmed=true;p.runs[i].error=error}
                else if cancelled || p.runs[i].status == .cancelling {p.runs[i].status = .cancelled}
                else if let result { p.runs[i].status = .succeeded;p.runs[i].result=result }
                else { p.runs[i].status = .failed;p.runs[i].error=error ?? "Calculation did not return a result." }
            }
        } catch {
            // The task is stopped, but a failed durable commit must never look like success.
            _=try? await store.update(id){p in if let i=p.runs.firstIndex(where:{$0.id==runID}){p.runs[i].status = .interrupted;p.runs[i].error="Result could not be saved: "+error.localizedDescription}}
        }
    }
    public func wait(_ id:UUID,runID:UUID) async throws -> BiologyRun {
        try await permit(.read,id)
        if let task=workers[runID] {await task.value}
        let p=try await store.load(id)
        guard let run=p.runs.first(where:{$0.id==runID}) else {throw BiologyError.invalid("Calculation no longer exists.")};return run
    }
    public func cancel(_ id:UUID,runID:UUID) async throws {
        try await permit(.compute,id)
        let p=try await store.load(id)
        guard let run=p.runs.first(where:{$0.id==runID}),run.isActive,let task=workers[runID],let backend=backends[run.environmentID] else {throw BiologyError.unavailable("This worker must be reconciled by its owning host.")}
        try await backend.cancel(runID:runID) // Remote adapters must await a genuine stop acknowledgement.
        _=try await store.update(id){p in if let i=p.runs.firstIndex(where:{$0.id==runID}),p.runs[i].isActive {p.runs[i].status = .cancelling}}
        task.cancel();await task.value
    }
    /// Host-only reconciliation after its execution service has independently
    /// confirmed the exact owned worker is gone. This is never a model tool.
    public func reconcileStoppedWorker(_ id:UUID,runID:UUID,owner:BiologyExecutionOwner,environmentID:String) async throws {
        try await permit(.compute,id)
        guard workers[runID]==nil else {throw BiologyError.invalid("Wait for the current worker to finish reconciliation.")}
        _=try await store.update(id){p in
            guard let i=p.runs.firstIndex(where:{$0.id==runID}),p.runs[i].owner==owner,p.runs[i].environmentID==environmentID,p.runs[i].workerStopUnconfirmed==true else {throw BiologyError.invalid("Worker reconciliation identity does not match.")}
            p.runs[i].workerStopUnconfirmed=nil;p.runs[i].status = .interrupted;p.runs[i].error="Host confirmed the previous worker stopped. No result was applied."
        };changed(id)
    }
    /// Called by the host once at process startup after it has established that
    /// previous native workers are gone. External jobs need their host reconciler.
    public func recoverInterruptedNativeRuns() async throws {
        try await permit(.edit)
        for p in try await store.list() {
            let ids=Set(p.runs.filter{$0.environmentID=="native.local" && $0.isActive && workers[$0.id]==nil}.map(\.id))
            if !ids.isEmpty { _=try await store.update(p.id){current in for i in current.runs.indices where ids.contains(current.runs[i].id){current.runs[i].status = .interrupted;current.runs[i].error="The application stopped before this native calculation completed."}} }
        }
    }
    public func applySequenceResult(_ id:UUID,runID:UUID) async throws -> BiologyAsset {
        let p=try await project(id)
        guard let run=p.runs.first(where:{$0.id==runID}),["sequence.reverseComplement","sequence.translate","seq.reverseComplement","seq.translate"].contains(run.method) else {throw BiologyError.invalid("Choose a sequence result.")}
        return try await deriveAsset(id,runID:runID)
    }
    public nonisolated static let derivableMethods:Set<String>=["sequence.reverseComplement","sequence.translate","seq.reverseComplement","seq.translate","seq.phylogeny","micro.import","micro.tile","omics.import","matrix.normalize","matrix.log1p","omics.normalize"]
    public func deriveAsset(_ id:UUID,runID:UUID,identity:BiologyMutationIdentity? = nil) async throws -> BiologyAsset {
        try await permit(.edit,id)
        if let identity,let bytes=try await store.receipt(id,identity:identity) {
            let assetID=try JSONDecoder().decode(UUID.self,from:bytes)
            guard let asset=try await store.load(id).assets.first(where:{$0.id==assetID}) else {throw BiologyError.invalid("The derived dataset was subsequently removed.")};return asset
        }
        let p=try await store.load(id)
        guard let run=p.runs.first(where:{$0.id==runID}),run.status == .succeeded,let result=run.result,
              Self.derivableMethods.contains(run.method),
              let source=p.assets.first(where:{$0.id==run.assetID}),source.revision==run.assetRevision,
              BiologyProjectStore.digest(try BiologyCoding.encode(source))==run.inputDigest else {throw BiologyError.invalid("This result does not match the current input. Its historical result remains available.")}
        let payload:BiologyAssetPayload
        if ["sequence.reverseComplement","sequence.translate","seq.reverseComplement","seq.translate"].contains(run.method) {
            let alphabet:String
            if run.method.hasSuffix("translate") {alphabet="protein"}
            else if case .sequence(let records)=source.payload,let raw=run.options["record"]?.number,Int(exactly:raw) != nil,records.indices.contains(Int(raw)) {alphabet=records[Int(raw)].alphabet}
            else if case .sequence(let records)=source.payload {alphabet=records.first?.alphabet ?? "dna"}
            else {alphabet="dna"}
            payload = .sequence([.init(name:source.title+" result",sequence:result.text,alphabet:alphabet)])
        } else if run.method=="seq.phylogeny" {
            _=try BiologyTree.parse(Data(result.text.utf8));payload = .externalDataset("newick")
        } else if run.method=="micro.import" || run.method=="micro.tile" {
            let image=try JSONDecoder().decode(MicroscopyImage.self,from:Data(result.text.utf8));try image.validate();payload = .microscopyImage(image)
        } else if run.method=="omics.import" {
            let matrix=try JSONDecoder().decode(ExpressionMatrix.self,from:Data(result.text.utf8));try matrix.validate();payload = .expressionMatrix(matrix)
        } else {
            let matrix=ExpressionMatrix(geneIDs:result.rowNames,cellIDs:result.columns,values:result.rows.flatMap{$0})
            try matrix.validate();payload = .expressionMatrix(matrix)
        }
        var asset=BiologyAsset(title:source.title+" result",payload:payload,originalData:run.method=="seq.phylogeny" ? Data(result.text.utf8):try BiologyCoding.encode(payload),originalFormat:run.method=="seq.phylogeny" ? "newick":"json")
        asset.provenance=["sourceAsset":source.id.uuidString,"sourceRun":run.id.uuidString,"sourceDigest":run.inputDigest]
        let derived=asset
        let savedID=try await store.transact(id,identity:identity){current in
            guard current.assets.first(where:{$0.id==source.id})==source else {throw BiologyError.invalid("The input changed before applying the result.")}
            current.assets.append(derived)
            return derived.id
        }
        guard let savedAsset=try await store.load(id).assets.first(where:{$0.id==savedID}) else {throw BiologyError.invalid("The derived dataset was subsequently removed.")}
        changed(id);return savedAsset
    }
}

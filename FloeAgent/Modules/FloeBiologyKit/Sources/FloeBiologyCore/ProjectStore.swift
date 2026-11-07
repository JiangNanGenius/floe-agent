// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

public actor BiologyProjectStore {
    public nonisolated let root: URL
    public static let maximumProjectBytes = 64 * 1024 * 1024
    private let fm = FileManager.default
    private struct Head: Codable { var revision: UInt64; var digest: String }
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try Self.ensureDirectory(self.root)
        try Self.ensureDirectory(self.root.appendingPathComponent("Trash"))
    }
    public nonisolated static func digest(_ bytes: Data) -> String { SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() }
    private nonisolated static func ensureDirectory(_ url:URL) throws {
        let fm=FileManager.default
        if fm.fileExists(atPath:url.path) {
            let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isDirectory==true,values.isSymbolicLink != true else { throw BiologyError.corrupt("Project storage contains a symbolic link or invalid directory.") }
        } else { try fm.createDirectory(at:url,withIntermediateDirectories:true) }
        guard url.resolvingSymlinksInPath().standardizedFileURL==url.standardizedFileURL else { throw BiologyError.corrupt("Project storage must not traverse symbolic links.") }
    }
    private func directory(_ id:UUID) throws -> URL { try Self.ensureDirectory(root);return root.appendingPathComponent(id.uuidString.lowercased(),isDirectory:true) }
    private func locked<T>(_ body:()throws->T) throws -> T {
        try Self.ensureDirectory(root)
        let fd=open(root.appendingPathComponent(".store.lock").path,O_RDWR|O_CREAT|O_NOFOLLOW,0o600)
        guard fd>=0 else { throw BiologyError.corrupt("Unable to acquire project storage.") }
        defer { _=flock(fd,LOCK_UN);close(fd) }
        guard flock(fd,LOCK_EX)==0 else { throw BiologyError.corrupt("Unable to lock project storage.") }
        return try body()
    }
    private func read(_ url:URL,maximum:Int = BiologyProjectStore.maximumProjectBytes) throws -> Data {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else { throw BiologyError.corrupt("A saved project file is missing or unsafe.") };defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>0,info.st_size<=maximum else { throw BiologyError.corrupt("Saved data exceeds its size limit or is not a regular file.") }
        var data=Data(count:Int(info.st_size))
        let size=data.count
        try data.withUnsafeMutableBytes { buffer in
            var offset=0
            while offset<size {
                let n=Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),size-offset)
                guard n>0 else { throw BiologyError.corrupt("Saved data was truncated.") };offset+=n
            }
        }
        return data
    }
    private func current(_ id:UUID) throws -> BiologyProject {
        let dir=try directory(id)
        guard fm.fileExists(atPath:dir.path) else { throw BiologyError.unavailable("Project does not exist.") }
        try Self.ensureDirectory(dir)
        let head=try JSONDecoder().decode(Head.self,from:read(dir.appendingPathComponent("HEAD.json"),maximum:4096))
        let revisions=dir.appendingPathComponent("revisions");try Self.ensureDirectory(revisions)
        let bytes=try read(revisions.appendingPathComponent("\(head.revision).json"))
        guard Self.digest(bytes)==head.digest else { throw BiologyError.corrupt("Project integrity verification failed; previous revisions remain available.") }
        let p=try JSONDecoder().decode(BiologyProject.self,from:bytes)
        guard p.id==id,p.revision==head.revision else { throw BiologyError.corrupt("Project identity does not match its saved revision.") }
        try Self.validate(p);return p
    }
    private func commit(_ project:BiologyProject) throws {
        try Self.validate(project)
        let data=try BiologyCoding.encode(project)
        guard data.count<=Self.maximumProjectBytes else { throw BiologyError.invalid("Project exceeds 64 MiB. Export or split the project before saving.") }
        let dir=try directory(project.id);try Self.ensureDirectory(dir)
        let revisions=dir.appendingPathComponent("revisions");try Self.ensureDirectory(revisions)
        let file=revisions.appendingPathComponent("\(project.revision).json")
        // Revisions are immutable. A crash between writing a revision and its
        // HEAD leaves recoverable bytes; it cannot overwrite the previous HEAD.
        if fm.fileExists(atPath:file.path) {
            guard try read(file)==data else { throw BiologyError.corrupt("An uncommitted revision conflicts with this save; recovery is required.") }
        } else { try data.write(to:file,options:.atomic) }
        let head=try BiologyCoding.encode(Head(revision:project.revision,digest:Self.digest(data)))
        try head.write(to:dir.appendingPathComponent("HEAD.json"),options:.atomic)
    }
    public nonisolated static func validate(_ p:BiologyProject) throws {
        guard p.schemaVersion==1,!p.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,p.title.utf8.count<=4096,
              p.assets.count<=256,p.runs.count<=1024,p.notes.utf8.count<=1_048_576,
              Set(p.assets.map(\.id)).count==p.assets.count,Set(p.runs.map(\.id)).count==p.runs.count else { throw BiologyError.invalid("Invalid project structure.") }
        for a in p.assets {
            guard a.originalData.count<=BiologyImporter.maximumInputBytes,a.revision>0,!a.title.isEmpty,a.title.utf8.count<=4096 else { throw BiologyError.invalid("Invalid asset size, name or revision.") }
            if let reference=a.fileReference {try reference.validate();guard reference.projectID==p.id else {throw BiologyError.invalid("Referenced file belongs to another project.")}}
            switch a.payload {
            case .sequence(let records):
                guard !records.isEmpty,records.count<=256,Set(records.map(\.id)).count==records.count else { throw BiologyError.invalid("Invalid sequence collection.") }
                for r in records {
                    try BiologyImporter.validateSequence(r.sequence)
                    guard r.quality.map({$0.utf8.count==r.sequence.utf8.count}) ?? true,
                          r.annotations.count<=100_000,
                          r.annotations.allSatisfy({$0.start>=0 && $0.end>$0.start && $0.end<=r.sequence.count && [-1,0,1].contains($0.strand)}) else { throw BiologyError.invalid("Sequence annotations or qualities are inconsistent.") }
                }
            case .proteinStructure(let s):
                guard !s.atoms.isEmpty,s.atoms.count<=100_000,Set(s.atoms.map(\.id)).count==s.atoms.count,
                      s.atoms.allSatisfy({[$0.x,$0.y,$0.z,$0.occupancy].allSatisfy(\.isFinite)}) else { throw BiologyError.invalid("Invalid protein coordinates.") }
            case .microscopyImage(let image):try image.validate()
            case .expressionMatrix(let matrix):try matrix.validate()
            case .biochemicalNetwork(let network):try network.validate()
            case .externalDataset:break
            }
        }
        if let active=p.activeAssetID,!p.assets.contains(where:{$0.id==active}) {throw BiologyError.invalid("Selected dataset is missing.")}
        guard (p.selections?.count ?? 0)<=256,(p.mutationReceipts?.count ?? 0)<=256 else {throw BiologyError.invalid("Project state budget exceeded.")}
        for (key,selection) in p.selections ?? [:] {
            guard let id=UUID(uuidString:key),let asset=p.assets.first(where:{$0.id==id}) else {throw BiologyError.invalid("Selection refers to a missing dataset.")}
            try BiologySelection.validate(selection,asset:asset)
        }
        for receipt in p.mutationReceipts ?? [] {
            guard !receipt.identity.requestID.isEmpty,receipt.identity.requestID.utf8.count<=1024,receipt.identity.argumentDigest.count==64,receipt.result.count<=262_144 else {throw BiologyError.invalid("Invalid operation receipt.")}
        }
        for run in p.runs {
            guard run.inputDigest.count==64,run.inputDigest.allSatisfy({"0123456789abcdef".contains($0)}),!run.environmentID.isEmpty else { throw BiologyError.invalid("Invalid run identity.") }
            if let r=run.result {
                guard r.metrics.values.allSatisfy(\.isFinite),r.rows.count<=100_000,r.rows.allSatisfy({$0.allSatisfy(\.isFinite)}),r.labels.count<=4_194_304 else { throw BiologyError.invalid("Invalid or oversized analysis output.") }
            }
        }
    }
    /// Trusted host transaction only. A native document reservation may bind
    /// its already allocated identity without changing model-call identities.
    /// Existing originals (including deleted/recoverable ones) are never reused.
    public func createBound(id:UUID,title:String) throws -> BiologyProject {
        try locked {
            let trash=root.appendingPathComponent("Trash")
            let prefix=id.uuidString.lowercased()
            let legacy=try fm.contentsOfDirectory(at:trash,includingPropertiesForKeys:nil)
                .contains{$0.lastPathComponent==prefix+".json" || $0.lastPathComponent.hasPrefix(prefix+"-")}
            guard !legacy,!fm.fileExists(atPath:try directory(id).path) else {
                throw BiologyError.invalid("This reserved project identity already exists. Keep the existing original.")
            }
            var project=BiologyProject(title:title)
            project.id=id;project.revision=1
            try commit(project)
            return project
        }
    }
    public func create(title:String,identity:BiologyMutationIdentity? = nil,contents:BiologyProject? = nil) throws -> BiologyProject {
        try locked {
            var p=contents ?? BiologyProject(title:title);p.id=UUID()
            if let identity {
                guard !identity.requestID.isEmpty,identity.requestID.utf8.count<=1024,identity.argumentDigest.count==64 else {throw BiologyError.invalid("Invalid creation identity.")}
                let material=identity.owner.taskID.uuidString+":"+identity.owner.hostRunID.uuidString+":"+identity.requestID
                let h=Array(Self.digest(Data(material.utf8)).prefix(32))
                let value=String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32])
                p.id=UUID(uuidString:value)!
                if fm.fileExists(atPath:try directory(p.id).path) {
                    let existing=try current(p.id)
                    guard existing.createdByOperation==identity else {throw BiologyError.invalid("Creation identity already belongs to different arguments.")}
                    return existing
                }
                p.createdByOperation=identity
            }
            p.revision=1;try commit(p);return p
        }
    }
    /// The state change and replay receipt share one immutable revision/HEAD
    /// commit. Failed changes do not create a receipt or mutate the project.
    public func transact<T:Codable & Sendable>(_ id:UUID,expectedRevision:UInt64? = nil,identity:BiologyMutationIdentity?,_ change:@Sendable (inout BiologyProject)throws->T) throws -> T {
        try transactReceipt(id,expectedRevision:expectedRevision,identity:identity,change).value
    }
    public func receipt(_ id:UUID,identity:BiologyMutationIdentity) throws -> Data? {
        try locked {
            let project=try current(id)
            guard let receipt=project.mutationReceipts?.first(where:{$0.identity.owner==identity.owner && $0.identity.requestID==identity.requestID}) else {return nil}
            guard receipt.identity.argumentDigest==identity.argumentDigest else {throw BiologyError.invalid("Call identity was reused with different arguments.")}
            return receipt.result
        }
    }
    public func transactReceipt<T:Codable & Sendable>(_ id:UUID,expectedRevision:UInt64? = nil,identity:BiologyMutationIdentity?,includingDeleted:Bool=false,_ change:@Sendable (inout BiologyProject)throws->T) throws -> BiologyTransactionResult<T> {
        try locked {
            var project=try current(id)
            if let identity {
                guard !identity.requestID.isEmpty,identity.requestID.utf8.count<=1024,identity.argumentDigest.count==64 else {throw BiologyError.invalid("Invalid operation identity.")}
                if let receipt=project.mutationReceipts?.first(where:{$0.identity.owner==identity.owner && $0.identity.requestID==identity.requestID}) {
                    guard receipt.identity.argumentDigest==identity.argumentDigest else {throw BiologyError.invalid("This call identity already belongs to different arguments.")}
                    return BiologyTransactionResult(value:try JSONDecoder().decode(T.self,from:receipt.result),replayed:true)
                }
            }
            guard includingDeleted || project.deletedAt==nil else {throw BiologyError.unavailable("This project is in Recently Deleted.")}
            if let expectedRevision,project.revision != expectedRevision {throw BiologyError.conflict(expected:expectedRevision,actual:project.revision)}
            guard project.revision<UInt64.max else {throw BiologyError.invalid("Revision limit reached.")}
            let result=try change(&project)
            guard project.id==id else {throw BiologyError.invalid("An operation cannot change project identity.")}
            if let identity {
                let bytes=try BiologyCoding.encode(result)
                guard bytes.count<=262_144 else {throw BiologyError.invalid("Operation receipt is too large.")}
                var receipts=project.mutationReceipts ?? [];receipts.append(.init(identity:identity,result:bytes));project.mutationReceipts=Array(receipts.suffix(256))
            }
            project.revision+=1;project.modifiedAt=Date();try commit(project);return BiologyTransactionResult(value:result,replayed:false)
        }
    }
    public func load(_ id:UUID) throws -> BiologyProject {try locked {let p=try current(id);guard p.deletedAt==nil else {throw BiologyError.unavailable("Project is in Recently Deleted.")};return p}}
    public func list() throws -> [BiologyProject] {
        try locked {
            try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{UUID(uuidString:$0.lastPathComponent) != nil}.map { try current(UUID(uuidString:$0.lastPathComponent)!) }.filter{$0.deletedAt==nil}.sorted{$0.modifiedAt>$1.modifiedAt}
        }
    }
    public func update(_ id:UUID,expectedRevision:UInt64? = nil,_ change:@Sendable (inout BiologyProject)throws->Void) throws -> BiologyProject {
        try locked {
            var p=try current(id)
            guard p.deletedAt==nil else {throw BiologyError.unavailable("Project is in Recently Deleted.")}
            if let expectedRevision,expectedRevision != p.revision { throw BiologyError.conflict(expected:expectedRevision,actual:p.revision) }
            guard p.revision<UInt64.max else { throw BiologyError.invalid("Revision limit reached.") }
            try change(&p)
            guard p.id==id else {throw BiologyError.invalid("A project edit cannot change project identity.")}
            p.revision+=1;p.modifiedAt=Date();try commit(p);return p
        }
    }
    public func history(_ id:UUID) throws -> [UInt64] {
        try locked {
            _=try current(id)
            let dir=try directory(id).appendingPathComponent("revisions");try Self.ensureDirectory(dir)
            return try fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).compactMap{UInt64($0.deletingPathExtension().lastPathComponent)}.sorted(by:>)
        }
    }
    public func restore(_ id:UUID,revision:UInt64,expectedRevision:UInt64,identity:BiologyMutationIdentity? = nil) throws -> BiologyProject {
        try locked {
            let latest=try current(id)
            if let identity,let receipt=latest.mutationReceipts?.first(where:{$0.identity.owner==identity.owner && $0.identity.requestID==identity.requestID}) {
                guard receipt.identity.argumentDigest==identity.argumentDigest else {throw BiologyError.invalid("Call identity was reused with different arguments.")};return latest
            }
            guard latest.deletedAt==nil else {throw BiologyError.unavailable("Restore this deleted project before restoring a version.")}
            guard latest.revision==expectedRevision else { throw BiologyError.conflict(expected:expectedRevision,actual:latest.revision) }
            guard !latest.runs.contains(where:\.isActive),latest.revision<UInt64.max else { throw BiologyError.invalid("Stop active calculations before restoring history.") }
            var restored=try JSONDecoder().decode(BiologyProject.self,from:read(try directory(id).appendingPathComponent("revisions/\(revision).json")))
            guard restored.id==id else { throw BiologyError.corrupt("History belongs to a different project.") }
            for i in restored.assets.indices {
                let previous=latest.assets.first{$0.id==restored.assets[i].id}?.revision ?? latest.revision
                guard previous<UInt64.max else { throw BiologyError.invalid("Asset revision limit reached.") }
                restored.assets[i].revision=max(previous,latest.revision)+1
            }
            for i in restored.runs.indices where restored.runs[i].isActive { restored.runs[i].status = .interrupted;restored.runs[i].workerStopUnconfirmed=nil }
            restored.mutationReceipts=latest.mutationReceipts
            if let identity {
                var receipts=restored.mutationReceipts ?? []
                receipts.append(.init(identity:identity,result:try BiologyCoding.encode(latest.revision+1)));restored.mutationReceipts=Array(receipts.suffix(256))
            }
            restored.createdByOperation=latest.createdByOperation;restored.deletedAt=nil
            restored.revision=latest.revision+1;restored.modifiedAt=Date();try commit(restored);return restored
        }
    }
    public func trash(_ id:UUID,expectedRevision:UInt64? = nil,identity:BiologyMutationIdentity? = nil) throws {
        try locked {
            var p=try current(id)
            if let identity,let receipt=p.mutationReceipts?.first(where:{$0.identity.owner==identity.owner && $0.identity.requestID==identity.requestID}) {
                guard receipt.identity.argumentDigest==identity.argumentDigest else {throw BiologyError.invalid("Call identity was reused with different arguments.")};return
            }
            if p.deletedAt != nil {return}
            if let expectedRevision,p.revision != expectedRevision {throw BiologyError.conflict(expected:expectedRevision,actual:p.revision)}
            guard !p.runs.contains(where:\.isActive) else { throw BiologyError.invalid("Stop active calculations before moving this project to Recently Deleted.") }
            guard p.revision<UInt64.max else {throw BiologyError.invalid("Revision limit reached.")}
            p.deletedAt=Date();p.revision+=1;p.modifiedAt=Date()
            if let identity {
                var receipts=p.mutationReceipts ?? []
                receipts.append(.init(identity:identity,result:try BiologyCoding.encode(JSONValue.object(["deletedProjectID":.string(id.uuidString)]))))
                p.mutationReceipts=Array(receipts.suffix(256))
            }
            try commit(p)
            try Self.ensureDirectory(root.appendingPathComponent("Trash"))
            // The HEAD flag is authoritative. This small index is a recoverable
            // compatibility projection; a crash here cannot undo the deletion.
            try? BiologyCoding.encode(BiologyDeletedProject(id:id.uuidString.lowercased(),projectID:id,title:p.title,revision:p.revision)).write(to:root.appendingPathComponent("Trash/"+id.uuidString.lowercased()+".json"),options:.atomic)
        }
    }
    public func deletedProjects() throws -> [BiologyDeletedProject] {
        try locked {
            let trash=root.appendingPathComponent("Trash");try Self.ensureDirectory(trash)
            let modern=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{UUID(uuidString:$0.lastPathComponent) != nil}.map{try current(UUID(uuidString:$0.lastPathComponent)!)}.filter{$0.deletedAt != nil}.map{BiologyDeletedProject(id:$0.id.uuidString.lowercased(),projectID:$0.id,title:$0.title,revision:$0.revision)}
            let legacy=try fm.contentsOfDirectory(at:trash,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.count==73 && UUID(uuidString:String($0.lastPathComponent.prefix(36))) != nil && UUID(uuidString:String($0.lastPathComponent.suffix(36))) != nil}.map {dir in
                try Self.ensureDirectory(dir)
                let head=try JSONDecoder().decode(Head.self,from:read(dir.appendingPathComponent("HEAD.json"),maximum:4096))
                let data=try read(dir.appendingPathComponent("revisions/\(head.revision).json"))
                guard Self.digest(data)==head.digest else {throw BiologyError.corrupt("Deleted project failed integrity verification.")}
                let project=try JSONDecoder().decode(BiologyProject.self,from:data);try Self.validate(project)
                guard dir.lastPathComponent.hasPrefix(project.id.uuidString.lowercased()+"-") else {throw BiologyError.corrupt("Deleted project identity mismatch.")}
                return BiologyDeletedProject(id:dir.lastPathComponent,projectID:project.id,title:project.title,revision:project.revision)
            }
            return (modern+legacy).sorted{$0.title<$1.title}
        }
    }
    public func restoreDeleted(_ trashID:String,projectID:UUID,identity:BiologyMutationIdentity? = nil) throws -> BiologyProject {
        try locked {
            if trashID==projectID.uuidString.lowercased() {
                var p=try current(projectID)
                if let identity,let receipt=p.mutationReceipts?.first(where:{$0.identity.owner==identity.owner && $0.identity.requestID==identity.requestID}) {
                    guard receipt.identity.argumentDigest==identity.argumentDigest else {throw BiologyError.invalid("Call identity was reused with different arguments.")};return p
                }
                guard p.deletedAt != nil else {return p}
                guard p.revision<UInt64.max else {throw BiologyError.invalid("Revision limit reached.")}
                p.deletedAt=nil;p.revision+=1;p.modifiedAt=Date()
                if let identity {var receipts=p.mutationReceipts ?? [];receipts.append(.init(identity:identity,result:try BiologyCoding.encode(JSONValue.object(["restoredProjectID":.string(projectID.uuidString)]))));p.mutationReceipts=Array(receipts.suffix(256))}
                try commit(p)
                try? fm.removeItem(at:root.appendingPathComponent("Trash/"+trashID+".json"))
                return p
            }
            guard trashID.hasPrefix(projectID.uuidString.lowercased()+"-"),trashID.count==73,UUID(uuidString:String(trashID.suffix(36))) != nil else {throw BiologyError.invalid("Invalid deleted project identity.")}
            let source=root.appendingPathComponent("Trash/"+trashID);try Self.ensureDirectory(root.appendingPathComponent("Trash"))
            guard fm.fileExists(atPath:source.path) else {throw BiologyError.unavailable("Deleted project no longer exists.")}
            try Self.ensureDirectory(source)
            let head=try JSONDecoder().decode(Head.self,from:read(source.appendingPathComponent("HEAD.json"),maximum:4096))
            let bytes=try read(source.appendingPathComponent("revisions/\(head.revision).json"))
            guard Self.digest(bytes)==head.digest else {throw BiologyError.corrupt("Deleted project failed integrity verification.")}
            let project=try JSONDecoder().decode(BiologyProject.self,from:bytes)
            guard project.id==projectID else {throw BiologyError.corrupt("Deleted project identity mismatch.")};try Self.validate(project)
            let destination=try directory(projectID)
            guard !fm.fileExists(atPath:destination.path) else {throw BiologyError.invalid("A live project already uses this identity. The deleted copy was retained.")}
            try fm.moveItem(at:source,to:destination);return try current(projectID)
        }
    }
}
public struct BiologyTransactionResult<Value:Sendable>:Sendable {
    public var value:Value
    public var replayed:Bool
}
public struct BiologyDeletedProject:Codable,Sendable,Equatable,Identifiable {
    public var id:String
    public var projectID:UUID
    public var title:String
    public var revision:UInt64
}

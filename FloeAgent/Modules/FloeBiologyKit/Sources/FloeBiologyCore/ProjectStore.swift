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
    private nonisolated static func validate(_ p:BiologyProject) throws {
        guard p.schemaVersion==1,!p.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,p.title.utf8.count<=4096,
              p.assets.count<=256,p.runs.count<=1024,p.notes.utf8.count<=1_048_576,
              Set(p.assets.map(\.id)).count==p.assets.count,Set(p.runs.map(\.id)).count==p.runs.count else { throw BiologyError.invalid("Invalid project structure.") }
        for a in p.assets {
            guard a.originalData.count<=BiologyImporter.maximumInputBytes,a.revision>0,!a.title.isEmpty,a.title.utf8.count<=4096 else { throw BiologyError.invalid("Invalid asset size, name or revision.") }
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
        for run in p.runs {
            guard run.inputDigest.count==64,run.inputDigest.allSatisfy({"0123456789abcdef".contains($0)}),!run.environmentID.isEmpty else { throw BiologyError.invalid("Invalid run identity.") }
            if let r=run.result {
                guard r.metrics.values.allSatisfy(\.isFinite),r.rows.count<=100_000,r.rows.allSatisfy({$0.allSatisfy(\.isFinite)}),r.labels.count<=4_194_304 else { throw BiologyError.invalid("Invalid or oversized analysis output.") }
            }
        }
    }
    public func create(title:String) throws -> BiologyProject {
        try locked { var p=BiologyProject(title:title);p.revision=1;try commit(p);return p }
    }
    public func load(_ id:UUID) throws -> BiologyProject { try locked { try current(id) } }
    public func list() throws -> [BiologyProject] {
        try locked {
            try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{UUID(uuidString:$0.lastPathComponent) != nil}.map { try current(UUID(uuidString:$0.lastPathComponent)!) }.sorted{$0.modifiedAt>$1.modifiedAt}
        }
    }
    public func update(_ id:UUID,expectedRevision:UInt64? = nil,_ change:@Sendable (inout BiologyProject)throws->Void) throws -> BiologyProject {
        try locked {
            var p=try current(id)
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
    public func restore(_ id:UUID,revision:UInt64,expectedRevision:UInt64) throws -> BiologyProject {
        try locked {
            let latest=try current(id)
            guard latest.revision==expectedRevision else { throw BiologyError.conflict(expected:expectedRevision,actual:latest.revision) }
            guard !latest.runs.contains(where:\.isActive),latest.revision<UInt64.max else { throw BiologyError.invalid("Stop active calculations before restoring history.") }
            var restored=try JSONDecoder().decode(BiologyProject.self,from:read(try directory(id).appendingPathComponent("revisions/\(revision).json")))
            guard restored.id==id else { throw BiologyError.corrupt("History belongs to a different project.") }
            for i in restored.assets.indices {
                let previous=latest.assets.first{$0.id==restored.assets[i].id}?.revision ?? latest.revision
                guard previous<UInt64.max else { throw BiologyError.invalid("Asset revision limit reached.") }
                restored.assets[i].revision=max(previous,latest.revision)+1
            }
            for i in restored.runs.indices where restored.runs[i].isActive { restored.runs[i].status = .interrupted }
            restored.revision=latest.revision+1;restored.modifiedAt=Date();try commit(restored);return restored
        }
    }
    public func trash(_ id:UUID) throws {
        try locked {
            let p=try current(id)
            guard !p.runs.contains(where:\.isActive) else { throw BiologyError.invalid("Stop active calculations before moving this project to Recently Deleted.") }
            try fm.moveItem(at:try directory(id),to:root.appendingPathComponent("Trash/\(id.uuidString.lowercased())-\(UUID().uuidString)"))
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeBiologyCore
import Darwin

public struct BiologyFileContext:Sendable {
    public let projectID:UUID
    public let owner:BiologyExecutionOwner?
    public init(projectID:UUID,owner:BiologyExecutionOwner?) {self.projectID=projectID;self.owner=owner}
}
public struct BiologyExportReceipt:Codable,Sendable,Equatable {
    public var fileID:UUID
    public var projectID:UUID
    public var fileName:String
    public var byteCount:UInt64
    public var sha256:String
    public var environmentID:String
    public init(reference:BiologyFileReference) {
        fileID=reference.id;projectID=reference.projectID;fileName=reference.fileName;byteCount=reference.byteCount;sha256=reference.sha256;environmentID=reference.environmentID
    }
}
/// A native file-picker handoff. This is deliberately not Codable and is never
/// returned by the model tool interface.
public struct BiologyNativeFileExport:Identifiable,Sendable {
    public let id:UUID
    public let projectID:UUID
    public let url:URL
    public init(id:UUID,projectID:UUID,url:URL){self.id=id;self.projectID=projectID;self.url=url}
}
/// The App binds this to its existing file grants/workspace service. Models
/// receive opaque identities, never host paths or new filesystem authority.
public protocol BiologyFileAccessing:Sendable {
    func register(trustedSourceURL:URL,fileName:String,context:BiologyFileContext) async throws -> BiologyFileReference
    func resolve(_ fileID:UUID,context:BiologyFileContext) async throws -> BiologyFileReference
    func read(_ reference:BiologyFileReference,offset:UInt64,length:Int,context:BiologyFileContext) async throws -> Data
    func export(_ data:Data,fileName:String,context:BiologyFileContext) async throws -> BiologyExportReceipt
    func export(_ reference:BiologyFileReference,fileName:String,context:BiologyFileContext) async throws -> BiologyExportReceipt
    func prepareNativeExport(_ reference:BiologyFileReference,context:BiologyFileContext) async throws -> BiologyNativeFileExport
    func finishNativeExport(_ export:BiologyNativeFileExport) async
}
public extension BiologyFileAccessing {
    func register(trustedSourceURL:URL,fileName:String,context:BiologyFileContext) async throws -> BiologyFileReference {throw BiologyError.unavailable("This host has not connected its authorized file importer.")}
    func prepareNativeExport(_ reference:BiologyFileReference,context:BiologyFileContext) async throws -> BiologyNativeFileExport {throw BiologyError.unavailable("This host has not connected native file sharing.")}
    func finishNativeExport(_ export:BiologyNativeFileExport) async {}
}

/// Concrete immutable streaming file store for an explicitly host-authorized
/// workspace. Registration takes a trusted file-picker/service URL, never JSON.
public actor BiologyWorkspaceFiles:BiologyFileAccessing {
    public nonisolated let root:URL
    public nonisolated let environmentID:String
    private let authorize:@Sendable (BiologyFileContext,Bool) async throws -> Void
    private let maximumBytes:UInt64
    public init(root:URL,environmentID:String,maximumBytes:UInt64=8*1024*1024*1024,authorize:@escaping @Sendable (BiologyFileContext,Bool) async throws -> Void) throws {
        guard !environmentID.isEmpty,maximumBytes>0,maximumBytes<=512*1024*1024*1024 else {throw BiologyError.invalid("Invalid file-store configuration.")}
        self.root=root.standardizedFileURL;self.environmentID=environmentID;self.maximumBytes=maximumBytes;self.authorize=authorize
        try Self.directory(self.root)
    }
    private nonisolated static func directory(_ url:URL) throws {
        let fm=FileManager.default
        if !fm.fileExists(atPath:url.path) {try fm.createDirectory(at:url,withIntermediateDirectories:true)}
        let info=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard info.isDirectory==true,info.isSymbolicLink != true,url.resolvingSymlinksInPath().standardizedFileURL==url.standardizedFileURL else {throw BiologyError.corrupt("File storage traverses an unsafe directory.")}
    }
    private func directory(_ id:UUID,create:Bool=true) throws -> URL {
        let path=root.appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)
        if !create {guard FileManager.default.fileExists(atPath:path.path) else {throw BiologyError.unavailable("No authorized file has this identity.")}}
        try Self.directory(root);try Self.directory(path);return path
    }
    private func metadata(_ id:UUID,projectID:UUID) throws -> BiologyFileReference {
        let dir=try directory(projectID,create:false),path=dir.appendingPathComponent(id.uuidString.lowercased()+".json")
        let fd=open(path.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw BiologyError.unavailable("No authorized file has this identity.")};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>0,info.st_size<=16384 else {throw BiologyError.corrupt("Invalid file metadata.")}
        let data=try Self.readFD(fd,count:Int(info.st_size))
        let reference=try JSONDecoder().decode(BiologyFileReference.self,from:data);try reference.validate()
        guard reference.id==id,reference.projectID==projectID,reference.environmentID==environmentID,reference.byteCount<=maximumBytes else {throw BiologyError.corrupt("File ownership did not validate.")}
        return reference
    }
    private nonisolated static func readFD(_ fd:Int32,count:Int) throws -> Data {
        var data=Data(count:count)
        try data.withUnsafeMutableBytes {buffer in
            var offset=0
            while offset<count {
                let readCount=Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),count-offset)
                guard readCount>0 else {throw BiologyError.corrupt("File was truncated while reading.")}
                offset+=readCount
            }
        };return data
    }
    private func validatedFD(_ reference:BiologyFileReference,projectID:UUID) throws -> Int32 {
        guard try metadata(reference.id,projectID:projectID)==reference else {throw BiologyError.corrupt("File reference is stale or belongs to another dataset.")}
        let path=try directory(projectID,create:false).appendingPathComponent(reference.id.uuidString.lowercased()+".bin")
        let fd=open(path.path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else {throw BiologyError.unavailable("Referenced file is unavailable.")}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>=0,UInt64(info.st_size)==reference.byteCount else {close(fd);throw BiologyError.corrupt("Referenced file size changed.")}
        return fd
    }
    @discardableResult public func register(trustedSourceURL:URL,fileName:String,context:BiologyFileContext) async throws -> BiologyFileReference {
        try await authorize(context,true)
        guard !fileName.isEmpty,fileName.utf8.count<=4096 else {throw BiologyError.invalid("Invalid file name.")}
        let fd=open(trustedSourceURL.path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else {throw BiologyError.unavailable("The authorized source file could not be opened.")};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>0,UInt64(info.st_size)<=maximumBytes else {throw BiologyError.invalid("Source file exceeds this workspace's configured limit.")}
        return try copy(fd:fd,byteCount:UInt64(info.st_size),fileName:fileName,projectID:context.projectID)
    }
    private func copy(fd:Int32,byteCount:UInt64,fileName:String,projectID:UUID) throws -> BiologyFileReference {
        var before=stat();guard fstat(fd,&before)==0 else {throw BiologyError.corrupt("Unable to inspect the source file.")}
        let dir=try directory(projectID),id=UUID()
        let staged=dir.appendingPathComponent(".pending-"+id.uuidString.lowercased())
        let destination=dir.appendingPathComponent(id.uuidString.lowercased()+".bin")
        let output=open(staged.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard output>=0 else {throw BiologyError.corrupt("Unable to stage the file.")}
        var committed=false
        defer{close(output);if !committed {try? FileManager.default.removeItem(at:staged)}}
        guard lseek(fd,0,SEEK_SET)>=0 else {throw BiologyError.corrupt("Source is not seekable.")}
        var hash=SHA256(),remaining=byteCount
        while remaining>0 {
            try Task.checkCancellation()
            let bytes=try Self.readFD(fd,count:Int(min(remaining,1_048_576)))
            hash.update(data:bytes)
            try bytes.withUnsafeBytes {buffer in
                var written=0
                while written<bytes.count {
                    let amount=Darwin.write(output,buffer.baseAddress!.advanced(by:written),bytes.count-written)
                    guard amount>0 else {throw BiologyError.corrupt("File write failed.")}
                    written+=amount
                }
            }
            remaining-=UInt64(bytes.count)
        }
        var info=stat();guard fstat(fd,&info)==0,UInt64(info.st_size)==byteCount,info.st_ino==before.st_ino,info.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,info.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,info.st_ctimespec.tv_sec==before.st_ctimespec.tv_sec,info.st_ctimespec.tv_nsec==before.st_ctimespec.tv_nsec,fsync(output)==0 else {throw BiologyError.corrupt("The source changed or the file could not be saved.")}
        let reference=BiologyFileReference(id:id,projectID:projectID,fileName:fileName,byteCount:byteCount,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined(),environmentID:environmentID)
        try FileManager.default.moveItem(at:staged,to:destination);committed=true
        do{try BiologyCoding.encode(reference).write(to:dir.appendingPathComponent(id.uuidString.lowercased()+".json"),options:.atomic)}
        catch{try? FileManager.default.removeItem(at:destination);throw error}
        return reference
    }
    public func resolve(_ fileID:UUID,context:BiologyFileContext) async throws -> BiologyFileReference {
        try await authorize(context,false);return try metadata(fileID,projectID:context.projectID)
    }
    public func read(_ reference:BiologyFileReference,offset:UInt64,length:Int,context:BiologyFileContext) async throws -> Data {
        try await authorize(context,false)
        guard length>=0,length<=2*1024*1024,offset<=reference.byteCount,UInt64(length)<=reference.byteCount-offset else {throw BiologyError.invalid("Choose a bounded range within the authorized file.")}
        let fd=try validatedFD(reference,projectID:context.projectID);defer{close(fd)}
        guard lseek(fd,off_t(offset),SEEK_SET)>=0 else {throw BiologyError.corrupt("Unable to select the file range.")}
        return try Self.readFD(fd,count:length)
    }
    public func export(_ data:Data,fileName:String,context:BiologyFileContext) async throws -> BiologyExportReceipt {
        try await authorize(context,true)
        guard !data.isEmpty,data.count<=BiologyProjectStore.maximumProjectBytes else {throw BiologyError.invalid("Empty or oversized output.")}
        let dir=try directory(context.projectID),temp=dir.appendingPathComponent(".export-"+UUID().uuidString.lowercased())
        try data.write(to:temp,options:.atomic);defer{try? FileManager.default.removeItem(at:temp)}
        let fd=open(temp.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw BiologyError.corrupt("Unable to open staged output.")};defer{close(fd)}
        return BiologyExportReceipt(reference:try copy(fd:fd,byteCount:UInt64(data.count),fileName:fileName,projectID:context.projectID))
    }
    public func export(_ reference:BiologyFileReference,fileName:String,context:BiologyFileContext) async throws -> BiologyExportReceipt {
        try await authorize(context,true)
        let fd=try validatedFD(reference,projectID:context.projectID);defer{close(fd)}
        let result=try copy(fd:fd,byteCount:reference.byteCount,fileName:fileName,projectID:context.projectID)
        guard result.sha256==reference.sha256 else {
            let directory=try directory(context.projectID,create:false)
            for suffix in [".bin",".json"] {try? FileManager.default.removeItem(at:directory.appendingPathComponent(result.id.uuidString.lowercased()+suffix))}
            throw BiologyError.corrupt("Original file changed; the exported copy was not accepted.")
        }
        return BiologyExportReceipt(reference:result)
    }
    public func prepareNativeExport(_ reference:BiologyFileReference,context:BiologyFileContext) async throws -> BiologyNativeFileExport {
        try await authorize(context,true)
        let fd=try validatedFD(reference,projectID:context.projectID);defer{close(fd)}
        let exports=root.appendingPathComponent(".native-exports",isDirectory:true)
        try Self.directory(exports)
        let id=UUID(),directory=exports.appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)
        try Self.directory(directory)
        var complete=false
        defer{if !complete {try? FileManager.default.removeItem(at:directory)}}
        let proposed=URL(fileURLWithPath:reference.fileName).lastPathComponent
        let name=proposed.isEmpty || proposed=="." || proposed==".." ? "Biology-export":String(proposed.prefix(180))
        let url=directory.appendingPathComponent(name)
        let output=open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard output>=0 else {throw BiologyError.corrupt("Unable to prepare the file for sharing.")};defer{close(output)}
        var before=stat();guard fstat(fd,&before)==0 else {throw BiologyError.corrupt("Unable to inspect the original file.")}
        var remaining=reference.byteCount,hash=SHA256()
        while remaining>0 {
            try Task.checkCancellation()
            let bytes=try Self.readFD(fd,count:Int(min(remaining,1_048_576)));hash.update(data:bytes)
            try bytes.withUnsafeBytes {buffer in
                var written=0
                while written<bytes.count {
                    let count=Darwin.write(output,buffer.baseAddress!.advanced(by:written),bytes.count-written)
                    guard count>0 else {throw BiologyError.corrupt("Unable to prepare the shared file.")};written+=count
                }
            };remaining-=UInt64(bytes.count)
        }
        var after=stat()
        guard fstat(fd,&after)==0,after.st_size==before.st_size,after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,after.st_ctimespec.tv_sec==before.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==before.st_ctimespec.tv_nsec,fsync(output)==0,
              hash.finalize().map({String(format:"%02x",$0)}).joined()==reference.sha256 else {throw BiologyError.corrupt("The original file changed while preparing the export.")}
        complete=true;return .init(id:id,projectID:context.projectID,url:url)
    }
    public func finishNativeExport(_ export:BiologyNativeFileExport) async {
        let directory=root.appendingPathComponent(".native-exports").appendingPathComponent(export.id.uuidString.lowercased())
        guard export.url.deletingLastPathComponent().standardizedFileURL==directory.standardizedFileURL else {return}
        try? FileManager.default.removeItem(at:directory)
    }
    /// Trusted bridge use only. Relative to this configured workspace, derived
    /// from UUIDs after authorization; never a path decoded from a model.
    public func relativePath(_ reference:BiologyFileReference,context:BiologyFileContext) async throws -> String {
        try await authorize(context,false)
        let fd=try validatedFD(reference,projectID:context.projectID);close(fd)
        return reference.projectID.uuidString.lowercased()+"/"+reference.id.uuidString.lowercased()+".bin"
    }
}

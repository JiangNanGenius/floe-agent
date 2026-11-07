// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto
import Darwin
import FloeTools

/// The single CAD machining sidecar convention shared by the native host and
/// guarded workspace file operations. Ordinary files never enter this path.
public enum CADMachiningCompanion {
    public static func directory(forCADURL url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.lastPathComponent.utf8)).map { String(format:"%02x",$0) }.joined()
        return url.deletingLastPathComponent().appendingPathComponent(".floe-machining",isDirectory:true)
            .appendingPathComponent(String(key.prefix(24)),isDirectory:true)
    }

    /// A shared lease spans an actual write/computation or open workbench.
    /// Transfers take an exclusive lease under WorkspaceFileService's existing
    /// mutation lock. The lease file stays outside the directory being moved.
    public static func storageLease(cadURL: URL, directory: URL) throws -> AnyObject {
        guard FileManager.default.fileExists(atPath:cadURL.path) else {
            throw WorkspaceToolError.invalidArguments(text("CAD 文档的位置已改变，请重新打开后编辑加工设置。","The CAD document moved. Reopen it before editing machining settings."))
        }
        try rejectLink(directory.deletingLastPathComponent()); try rejectLink(directory)
        let lease = try Lease(directory:directory,exclusive:false)
        guard FileManager.default.fileExists(atPath:cadURL.path) else { throw WorkspaceToolError.notFound(cadURL.lastPathComponent) }
        return lease
    }

    public static func locationGeneration(directory:URL) throws -> Data {
        let file = directory.appendingPathComponent("location-generation")
        try rejectLink(file)
        guard FileManager.default.fileExists(atPath:file.path) else { return Data() }
        guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 128 else { throw WorkspaceToolError.invalidArguments(text("加工资料的位置记录无效，请重新打开文档。","The machining location record is invalid. Reopen the document.")) }
        return try Data(contentsOf:file)
    }

    /// Called only while the service's root mutation lock is held. Returns
    /// false for files/packages without this companion, preserving old behavior.
    static func transferIfPresent(source:URL,destination:URL,copy:Bool,
                                  guard pathGuard:WorkspacePathGuard,
                                  mutationGuard:(@Sendable (URL)throws->Void)?,
                                  cancellation:CancellationToken?) throws -> Bool {
        let fm = FileManager.default
        guard source.pathExtension.lowercased() == "floecad",
              fm.fileExists(atPath:source.appendingPathComponent("manifest.json").path),
              fm.fileExists(atPath:source.appendingPathComponent("document.json").path) else { return false }
        let original = directory(forCADURL:source), target = directory(forCADURL:destination)
        try pathGuard.assertWritable(original); try pathGuard.assertWritable(target)
        try rejectLink(original.deletingLastPathComponent()); try rejectLink(original)
        guard fm.fileExists(atPath:original.path) else { return false }
        guard destination.pathExtension.lowercased() == "floecad" else {
            throw WorkspaceToolError.invalidArguments(text("移动带有加工资料的 CAD 文档时，请保留 .floecad 扩展名。","Keep the .floecad extension when moving a CAD document with machining data."))
        }
        try rejectLink(target.deletingLastPathComponent()); try rejectLink(target)
        try mutationGuard?(original); try mutationGuard?(target)
        guard !fm.fileExists(atPath:target.path) else { throw WorkspaceToolError.alreadyExists(destination.lastPathComponent) }
        let first = try Lease(directory: original.path < target.path ? original : target,exclusive:true)
        let second = try Lease(directory: original.path < target.path ? target : original,exclusive:true)
        defer { withExtendedLifetime(first) {}; withExtendedLifetime(second) {} }
        try cancellation?.throwIfCancelled()
        guard !fm.fileExists(atPath:destination.path), !fm.fileExists(atPath:target.path) else { throw WorkspaceToolError.alreadyExists(destination.lastPathComponent) }
        let journalDirectory = original.deletingLastPathComponent().appendingPathComponent(".transactions",isDirectory:true)
        try pathGuard.assertWritable(journalDirectory); try rejectLink(journalDirectory)
        try fm.createDirectory(at:journalDirectory,withIntermediateDirectories:true)
        let operationID = UUID().uuidString.lowercased()
        let journal = journalDirectory.appendingPathComponent(operationID+".json")
        let stage = target.deletingLastPathComponent().appendingPathComponent(".copy-"+operationID,isDirectory:true)
        let stagedCAD = destination.deletingLastPathComponent().appendingPathComponent("."+destination.lastPathComponent+".copy-"+operationID,isDirectory:true)
        try pathGuard.assertWritable(stage); try pathGuard.assertWritable(stagedCAD)
        var receipt:[String:Any] = ["formatVersion":1,"operationID":operationID,"operation":copy ? "copy":"move",
            "sourceCAD":source.path,"destinationCAD":destination.path,"sourceCompanion":original.path,"destinationCompanion":target.path]
        func record(_ state:String,_ error:String? = nil) throws {
            receipt["state"] = state; receipt["updatedAt"] = Date().timeIntervalSince1970
            if let error { receipt["error"] = error }
            try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]).write(to:journal,options:.atomic)
        }
        try record("prepared")
        var companionPromoted = false, cadPromoted = false
        do {
            try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            if copy {
                try fm.copyItem(at:source,to:stagedCAD)
                let recovery = stage.appendingPathComponent("recovery/original-job",isDirectory:true)
                try fm.createDirectory(at:recovery.deletingLastPathComponent(),withIntermediateDirectories:true)
                try fm.copyItem(at:original,to:recovery)
                try verifyCopy(original,recovery,cancellation:cancellation)
                try prepareCopiedDraft(original:original,target:stage)
                try cancellation?.throwIfCancelled()
                try fm.moveItem(at:stage,to:target); companionPromoted = true
                try fm.moveItem(at:stagedCAD,to:destination); cadPromoted = true
            } else {
                try fm.moveItem(at:original,to:target); companionPromoted = true
                try fm.moveItem(at:source,to:destination); cadPromoted = true
            }
            try Data(operationID.utf8).write(to:target.appendingPathComponent("location-generation"),options:.atomic)
            try record("committed")
            return true
        } catch {
            let originalError = error.localizedDescription
            var recoveryErrors:[String] = []
            func recover(_ action:()throws->Void) { do { try action() } catch { recoveryErrors.append(error.localizedDescription) } }
            if copy {
                if cadPromoted { recover { try fm.removeItem(at:destination) } }
                if companionPromoted { recover { try fm.removeItem(at:target) } }
                for url in [stage,stagedCAD] where fm.fileExists(atPath:url.path) { recover { try fm.removeItem(at:url) } }
            } else {
                if cadPromoted { recover { try fm.moveItem(at:destination,to:source) } }
                if companionPromoted { recover { try fm.moveItem(at:target,to:original) } }
            }
            let details = ([originalError]+recoveryErrors).joined(separator:"; ")
            recover { try record(recoveryErrors.isEmpty ? "rolledBack":"recoveryRequired",details) }
            throw WorkspaceToolError.invalidArguments(text("CAD 与加工资料传输未完成：","CAD machining transfer failed: ")+([originalError]+recoveryErrors).joined(separator:"; ")+text("。恢复记录：",". Recovery record: ")+journal.path)
        }
    }

    private static func prepareCopiedDraft(original:URL,target:URL) throws {
        let fm = FileManager.default
        let draft = original.appendingPathComponent("draft.json"), archive = original.appendingPathComponent("latest.floemanufacturing")
        let input = fm.fileExists(atPath:draft.path) ? draft : archive
        try rejectLink(input)
        let size = try input.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size <= 64_000_000 else { throw WorkspaceToolError.invalidArguments(text("加工资料较大，无法复制此工艺设置。","The machining input exceeds the copy size limit.")) }
        guard let envelope = try JSONSerialization.jsonObject(with:Data(contentsOf:input)) as? [String:Any],
              var study = input == draft ? envelope : envelope["study"] as? [String:Any],
              let oldID = study["id"] as? String, UUID(uuidString:oldID) != nil,
              var source = study["source"] as? [String:Any] else {
            throw WorkspaceToolError.invalidArguments(text("请先打开 CAD 并保存加工设置，再复制文档。","Open and save the CAD machining settings before copying this document."))
        }
        let newID = UUID().uuidString.lowercased(), ownerID = UUID().uuidString.lowercased()
        let origin:[String:Any] = ["formatVersion":1,"originalStudyID":oldID,"originalSource":source,"newStudyID":newID,"newSourceOwnerID":ownerID]
        study["id"] = newID; source["documentID"] = "cad:"+ownerID; study["source"] = source
        try JSONSerialization.data(withJSONObject:study,options:[.sortedKeys]).write(to:target.appendingPathComponent("draft.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject:origin,options:[.sortedKeys]).write(to:target.appendingPathComponent("copy-origin.json"),options:.atomic)
    }

    private static func verifyCopy(_ source:URL,_ copy:URL,cancellation:CancellationToken?) throws {
        let fm = FileManager.default
        guard let files = fm.enumerator(at:source,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw WorkspaceToolError.notFound(source.lastPathComponent) }
        var count = 0
        for case let file as URL in files {
            try cancellation?.throwIfCancelled(); count += 1
            guard count <= 10_000 else { throw WorkspaceToolError.invalidArguments("Machining companion copy file budget exceeded.") }
            let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceToolError.invalidArguments("Machining companions cannot contain symbolic links.") }
            guard values.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(source.path.count+1))
            guard try digest(file) == digest(copy.appendingPathComponent(relative)) else { throw WorkspaceToolError.invalidArguments("Machining copy verification failed: "+relative) }
        }
    }
    private static func digest(_ url:URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount:1_048_576), !data.isEmpty { hash.update(data:data) }
        return hash.finalize()
    }
    private static func rejectLink(_ url:URL) throws {
        do {
            if let type = try FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw WorkspaceToolError.invalidArguments(text("加工资料目录不能使用符号链接。","Machining storage cannot be a symbolic link."))
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) {
            return
        }
    }
    private final class Lease {
        private let descriptor:Int32
        init(directory:URL,exclusive:Bool) throws {
            let folder = directory.deletingLastPathComponent().appendingPathComponent(".locks",isDirectory:true)
            try CADMachiningCompanion.rejectLink(folder)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let file = folder.appendingPathComponent(directory.lastPathComponent+".lock")
            let fileDescriptor = Darwin.open(file.path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
            guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            guard flock(fileDescriptor,(exclusive ? LOCK_EX:LOCK_SH)|LOCK_NB) == 0 else {
                let error = errno; Darwin.close(fileDescriptor)
                if error == EWOULDBLOCK { throw WorkspaceToolError.invalidArguments(CADMachiningCompanion.text("请先关闭加工工作台，或等待计算完成，再移动或复制 CAD 文档。","Close the machining workbench or wait for its calculation before moving or copying the CAD document.")) }
                throw POSIXError(POSIXErrorCode(rawValue:error) ?? .EIO)
            }
            descriptor = fileDescriptor
        }
        deinit { flock(descriptor,LOCK_UN); Darwin.close(descriptor) }
    }
    private static func text(_ zh:String,_ en:String) -> String { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh:en }
}

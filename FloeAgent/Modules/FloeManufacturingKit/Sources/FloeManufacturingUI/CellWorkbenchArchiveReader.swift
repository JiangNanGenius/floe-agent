// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Darwin
import FloeManufacturingCore

struct CellWorkbenchLoadSource:Sendable {
    let url:URL
    /// Non-nil only for the fixed latest.floecell in this workbench.
    let savedDirectory:URL?
}
struct CellWorkbenchLoadedDocument:Sendable {
    let project:ManufacturingCellProject
    let artifact:CellSimulationArtifact?
}

/// Off-main, bounded reads of an explicitly opened file. Presence checks do
/// not decode an archive, create a directory or run a manufacturing engine.
enum CellWorkbenchArchiveReader {
    static func hasSavedFile(in directory:URL) throws -> Bool {
        let root = Darwin.open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0, errno == ENOENT { return false }
        guard root >= 0 else { throw ManufacturingError.archive("Saved cell directory cannot be opened without following links") }
        defer { Darwin.close(root) }
        var value = stat()
        if fstatat(root,"latest.floecell",&value,AT_SYMLINK_NOFOLLOW) < 0 {
            if errno == ENOENT { return false }
            throw ManufacturingError.archive("Saved cell file could not be inspected")
        }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0, value.st_size <= ResearchArchive.byteLimit else {
            throw ManufacturingError.archive("Saved cell file type or size is invalid")
        }
        return true
    }
    static func load(_ source:CellWorkbenchLoadSource) async throws -> CellWorkbenchLoadedDocument {
        let operation = Task.detached(priority:.userInitiated) { try read(source) }
        return try await withTaskCancellationHandler(operation:{ try await operation.value },onCancel:{ operation.cancel() })
    }
    private static func read(_ source:CellWorkbenchLoadSource) throws -> CellWorkbenchLoadedDocument {
        try Task.checkCancellation()
        let access = source.url.startAccessingSecurityScopedResource()
        defer { if access { source.url.stopAccessingSecurityScopedResource() } }
        var root:Int32 = -1,rootIdentity = stat()
        if let directory = source.savedDirectory {
            guard source.url.standardizedFileURL == directory.appendingPathComponent("latest.floecell").standardizedFileURL else {
                throw ManufacturingError.stale
            }
            root = Darwin.open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ManufacturingError.archive("Saved cell directory is unavailable") }
            guard fstat(root,&rootIdentity) == 0 else { Darwin.close(root);throw ManufacturingError.stale }
        }
        defer { if root >= 0 { Darwin.close(root) } }
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let file = root >= 0 ? openat(root,"latest.floecell",flags):Darwin.open(source.url.path,flags)
        guard file >= 0 else { throw ManufacturingError.archive("Manufacturing cell file could not be opened") }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file,&before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= ResearchArchive.byteLimit else {
            throw ManufacturingError.archive("Manufacturing cell file type or size is invalid")
        }
        var bytes = Data();bytes.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating:0,count:64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file,$0.baseAddress!,$0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ManufacturingError.archive("Manufacturing cell read failed") }
            if count == 0 { break }
            guard bytes.count <= ResearchArchive.byteLimit - count else { throw ManufacturingError.archive("Manufacturing cell read byte budget exceeded") }
            bytes.append(contentsOf:buffer.prefix(count))
        }
        let result:CellWorkbenchLoadedDocument
        if source.savedDirectory == nil, source.url.pathExtension.lowercased() == "json" {
            let project = try JSONDecoder().decode(ManufacturingCellProject.self,from:bytes)
            try project.validate();result = .init(project:project,artifact:nil)
        } else {
            let (project,artifact) = try ManufacturingCellArchive.open(data:bytes)
            result = .init(project:project,artifact:artifact)
        }
        try Task.checkCancellation()
        var after = stat(),named = stat()
        let namedOK = root >= 0 ? fstatat(root,"latest.floecell",&named,AT_SYMLINK_NOFOLLOW):lstat(source.url.path,&named)
        guard fstat(file,&after) == 0, namedOK == 0, sameFile(before,after),sameFile(after,named),bytes.count == after.st_size else {
            throw ManufacturingError.stale
        }
        if let directory = source.savedDirectory {
            var current = stat()
            guard lstat(directory.path,&current) == 0, sameIdentity(rootIdentity,current) else { throw ManufacturingError.stale }
        }
        return result
    }
    private static func sameIdentity(_ a:stat,_ b:stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT)
    }
    private static func sameFile(_ a:stat,_ b:stat) -> Bool {
        sameIdentity(a,b) && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
#endif

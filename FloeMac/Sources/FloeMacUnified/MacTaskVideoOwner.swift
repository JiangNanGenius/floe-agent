// SPDX-License-Identifier: MPL-2.0
import Crypto
import Darwin
import Foundation
import FloeCore
import FloeModels
import FloeTools

/// The job's original workspace and output directory, captured before submission.
/// A restarted download must reacquire both identities before publishing its file.
struct MacTaskVideoOwner: Codable, Equatable, Sendable {
    let conversationID: UUID
    let runID: UUID
    let jobID: UUID
    let requestDigest: String
    let workspace: WorkspaceRecord
    let device: dev_t
    let inode: ino_t
    let destinationDevice: dev_t
    let destinationInode: ino_t

    static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    static func directoryName(_ conversationID: UUID) -> String { "GeneratedMedia/" + conversationID.uuidString }

    static func withRoot<T>(_ workspace: WorkspaceRecord, base: URL, conversationID: UUID,
                            _ action: (URL, MacAgentWorkspaceRoot, stat) throws -> T) throws -> T {
        var scoped: URL?
        defer { scoped?.stopAccessingSecurityScopedResource() }
        let url: URL
        switch workspace.kind {
        case .privateTask:
            guard let relative = workspace.internalRelativePath,
                  MacAgentWorkspaceTools.personalTaskID(relativePath: relative) == conversationID else {
                throw CocoaError(.fileReadNoPermission)
            }
            url = try MacAgentWorkspaceTools.verifiedPersonalTaskRoot(relativePath: relative, leaseBase: base, createIfNeeded: false)
        case .project:
            var stale = false
            url = try URL(resolvingBookmarkData: workspace.rootBookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, url.isFileURL else { throw CocoaError(.fileReadNoPermission) }
            if url.startAccessingSecurityScopedResource() { scoped = url }
        }
        let root = MacAgentWorkspaceRoot(url)
        var info = stat()
        guard let path = root.physicalPath, lstat(path, &info) == 0, root.matches(info) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try action(url, root, info)
    }

    static func capture(context: ToolContext, jobID: UUID, digest: String, workspace: WorkspaceRecord, base: URL) throws -> Self {
        guard let id = context.conversationID else { throw CocoaError(.fileWriteNoPermission) }
        return try withRoot(workspace, base: base, conversationID: id) { _, root, info in
            let directory = try MacTaskMediaDirectory(root: root, relativeDirectory: directoryName(id), context: context)
            return Self(conversationID: id, runID: context.runID, jobID: jobID, requestDigest: digest,
                        workspace: workspace, device: info.st_dev, inode: info.st_ino,
                        destinationDevice: directory.identity.device, destinationInode: directory.identity.inode)
        }
    }

    func publish(file: URL, privateTaskRootBase: URL, maximumBytes: Int) throws -> ToolArtifactReference {
        try Self.withRoot(workspace, base: privateTaskRootBase, conversationID: conversationID) { url, root, info in
            guard device == info.st_dev, inode == info.st_ino else { throw CocoaError(.fileWriteNoPermission) }
            let relative = Self.directoryName(conversationID)
            let name = file.lastPathComponent
            guard ["mp4","webm"].contains(file.pathExtension), name == jobID.uuidString + "." + file.pathExtension,
                  let physical = root.physicalPath else { throw CocoaError(.fileReadCorruptFile) }
            // Only finish the previously admitted file. Neither polling nor the provider chooses an output path.
            let context = ToolContext(runID: runID, workspaceRootURL: url, allowedWorkspacePaths: [relative], cancellation: .init(), conversationID: conversationID)
            try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: relative, root: root) { pin in
                var current = stat()
                guard fstatat(pin.parentFileDescriptor, pin.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == destinationDevice, current.st_ino == destinationInode else { throw CocoaError(.fileWriteNoPermission) }
            }
            let folder = try MacTaskMediaDirectory(root: root, relativeDirectory: relative, context: context)
            guard folder.identity.device == destinationDevice, folder.identity.inode == destinationInode else { throw CocoaError(.fileWriteNoPermission) }
            let fd = open(file.path, O_NOFOLLOW | O_NONBLOCK | O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
            let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let mimeType = file.pathExtension == "mp4" ? "video/mp4" : "video/webm"
            do {
                return try folder.commit(name: name, mimeType: mimeType, source: source, maximumBytes: maximumBytes, context: context)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // A crash after publication but before the receipt was flushed may leave the exact file.
                // Hash both bounded descriptors in chunks. An unrelated replacement is never accepted.
                return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: relative + "/" + name, root: root) { pin in
                    var parent = stat()
                    guard fstat(pin.parentFileDescriptor, &parent) == 0,
                          parent.st_dev == destinationDevice, parent.st_ino == destinationInode else { throw error }
                    let savedFD = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: name)
                    let saved = FileHandle(fileDescriptor: savedFD, closeOnDealloc: true)
                    let first = try Self.hash(source, maximum: maximumBytes)
                    let second = try Self.hash(saved, maximum: maximumBytes)
                    guard first == second else { throw error }
                    return .init(id: jobID, relativePath: relative + "/" + name, mimeType: mimeType, byteCount: first.0, sha256: first.1)
                }
            }
        }
    }

    func artifactIsAvailable(_ receipt: ToolArtifactReference, workspace: WorkspaceRecord, base: URL,
                             cancellation: CancellationToken) throws -> Bool {
        guard workspace.id == self.workspace.id else { return false }
        return try Self.withRoot(workspace, base: base, conversationID: conversationID) { _, root, info in
            let prefix = Self.directoryName(conversationID) + "/" + jobID.uuidString
            guard [prefix + ".mp4", prefix + ".webm"].contains(receipt.relativePath), receipt.byteCount > 0,
                  receipt.byteCount <= 512 * 1_048_576, info.st_dev == device, info.st_ino == inode,
                  let physical = root.physicalPath else { return false }
            return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: receipt.relativePath, root: root) { pin in
                var parent = stat()
                guard fstat(pin.parentFileDescriptor, &parent) == 0, parent.st_dev == destinationDevice,
                      parent.st_ino == destinationInode else { return false }
                let fd = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: receipt.relativePath)
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let result = try Self.hash(file, maximum: receipt.byteCount, cancellation: cancellation)
                return result == (receipt.byteCount, receipt.sha256)
            }
        }
    }

    private static func hash(_ file: FileHandle, maximum: Int, cancellation: CancellationToken? = nil) throws -> (Int, String) {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximum, info.st_nlink == 1 else { throw CocoaError(.fileReadCorruptFile) }
        try file.seek(toOffset: 0)
        var bytes = 0, digest = SHA256()
        while let data = try file.read(upToCount: 262_144), !data.isEmpty {
            try cancellation?.throwIfCancelled()
            try Task.checkCancellation()
            bytes += data.count
            guard bytes <= maximum else { throw CocoaError(.fileReadTooLarge) }
            digest.update(data: data)
        }
        guard bytes == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

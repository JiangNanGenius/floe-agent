// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Darwin
import FloeWorkspace
import FloeToolboxRemoteFiles

/// A byte-range bridge over an explicitly owned workspace or user-picked folder.
/// Existing workspace path/secret rules remain the path authority.
actor ToolboxLocalFileBackend: RemoteFileBackend {
    nonisolated let capabilities: Set<RemoteFileCapability> = [.list, .read, .write, .resumeRead, .resumeWrite, .createDirectory, .rename, .delete, .resolveLink, .atomicRename]
    private let guardResolver: WorkspacePathGuard
    private let service: WorkspaceFileService
    private let scopedURL: URL?
    private let scoped: Bool
    private var closed = false
    init(root: URL, scoped: Bool = false) {
        guardResolver = WorkspacePathGuard(rootURL: root)
        service = WorkspaceFileService(guard: guardResolver)
        scopedURL = scoped ? root : nil
        self.scoped = scoped ? root.startAccessingSecurityScopedResource() : false
    }
    private func relative(_ path: RemoteFilePath) throws -> String {
        guard !closed else { throw RemoteFileError.staleSession }; try Task.checkCancellation()
        _ = try path.validated(); return path.value == "/" ? "." : String(path.value.dropFirst())
    }
    private func url(_ path: RemoteFilePath) throws -> URL { try guardResolver.resolve(relative(path)) }
    private func metadataValue(_ path: RemoteFilePath) throws -> RemoteFileEntry {
        let location = try url(path)
        guard FileManager.default.fileExists(atPath: location.path) else { throw RemoteFileError.notFound }
        let values = try location.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        return .init(path: path, kind: values.isSymbolicLink == true ? .symbolicLink : values.isDirectory == true ? .directory : .file,
            revision: .init(byteCount: values.fileSize.map { UInt64(max(0, $0)) }, modifiedAt: values.contentModificationDate))
    }
    func list(_ path: RemoteFilePath) throws -> [RemoteFileEntry] {
        let relative = try relative(path)
        var result = [RemoteFileEntry](), cursor: String?
        repeat {
            let page = try service.listDirectory(relative, pageToken: cursor)
            for item in page.entries {
                let child = try path.appending(item.name)
                // Do not surface excluded credentials or links outside the selected root.
                guard (try? url(child)) != nil else { continue }
                result.append(try metadataValue(child))
            }
            cursor = page.nextPageToken
        } while cursor != nil
        return result
    }
    func metadata(_ path: RemoteFilePath) throws -> RemoteFileEntry { try metadataValue(path) }
    func read(_ path: RemoteFilePath, offset: UInt64, maximumBytes: Int) throws -> Data {
        guard (1...1_024 * 1_024).contains(maximumBytes) else { throw RemoteFileError.limit }
        let location = try url(path), fd = Darwin.open(location.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RemoteFileError.denied }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, offset <= UInt64(Int64.max) else { throw RemoteFileError.invalidPath }
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = pread(fd, &bytes, maximumBytes, off_t(offset)); guard count >= 0 else { throw RemoteFileError.connectionClosed }
        return Data(bytes.prefix(count))
    }
    func write(_ path: RemoteFilePath, offset: UInt64, bytes: Data, createExclusive: Bool) throws {
        guard bytes.count <= 1_024 * 1_024, offset <= UInt64(Int64.max), !createExclusive || offset == 0 else { throw RemoteFileError.limit }
        let location = try url(path); try guardResolver.assertWritable(location)
        let flags = O_WRONLY | O_NOFOLLOW | (createExclusive ? O_CREAT | O_EXCL : 0)
        let fd = Darwin.open(location.path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw errno == EEXIST ? RemoteFileError.conflict : RemoteFileError.denied }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RemoteFileError.invalidPath }
        try bytes.withUnsafeBytes { buffer in
            var done = 0
            while done < bytes.count {
                try Task.checkCancellation()
                let count = pwrite(fd, buffer.baseAddress!.advanced(by: done), bytes.count - done, off_t(offset) + off_t(done))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RemoteFileError.connectionClosed }; done += count
            }
        }
    }
    func createDirectory(_ path: RemoteFilePath) throws { try service.createDirectory(relative(path)) }
    func rename(_ source: RemoteFilePath, to destination: RemoteFilePath, replace: Bool) throws {
        let from = try url(source), to = try url(destination)
        guard from != guardResolver.rootURL, to != guardResolver.rootURL else { throw RemoteFileError.denied }
        try guardResolver.assertWritable(from); try guardResolver.assertWritable(to)
        let result = replace ? Darwin.rename(from.path, to.path) : renamex_np(from.path, to.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw errno == EEXIST ? RemoteFileError.conflict : RemoteFileError.denied }
    }
    func delete(_ path: RemoteFilePath, directory: Bool) throws { try service.delete(relative(path)) }
    func resolve(_ path: RemoteFilePath) throws -> RemoteFilePath {
        let location = try url(path), base = guardResolver.rootURL.path
        guard location.path == base || location.path.hasPrefix(base + "/") else { throw RemoteFileError.outsideRoot }
        return try RemoteFilePath(location.path == base ? "/" : String(location.path.dropFirst(base.count)))
    }
    func close() { guard !closed else { return }; closed = true; if scoped, let scopedURL { scopedURL.stopAccessingSecurityScopedResource() } }
    deinit { if !closed, scoped, let scopedURL { scopedURL.stopAccessingSecurityScopedResource() } }
}
#endif

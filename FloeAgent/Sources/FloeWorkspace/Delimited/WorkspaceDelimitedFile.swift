// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A bounded immutable source snapshot, opened only after the existing path
/// guard. Descriptor-relative no-follow opens and final bindings reject a
/// path/content replacement during reading or preparation. No writes occur.
public enum WorkspaceDelimitedFile {
    public static let maximumFileBytes = 10 * 1_024 * 1_024
    public struct Source: Codable, Sendable {
        public let path: String
        public let resolvedWorkspacePath: String
        public let sha256: String
        public let byteCount: Int
        public let encoding: ReaderTextEncoding
        public let encodingSelection: String
        public let bomBytes: Int
    }
    private struct Binding { let parent: Int32; let name: String; let child: Int32; let info: stat; let isFile: Bool }
    public static func read<Value>(path: String, pathGuard: WorkspacePathGuard,
                                   encoding: ReaderTextEncoding? = nil, expectedSHA256: String? = nil,
                                   checkCancellation: @Sendable () throws -> Void = {},
                                   authorizeResolved: (URL) throws -> Void = { _ in },
                                   prepare: (Source, String) throws -> Value) throws -> Value {
        try checkCancellation()
        let url = try pathGuard.resolve(path)
        try authorizeResolved(url)
        let rootURL = pathGuard.rootURL
        let prefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        guard url.path.hasPrefix(prefix) else { throw WorkspaceToolError.escapesRoot(path) }
        let relativePath = String(url.path.dropFirst(prefix.count))
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw DelimitedTable.Failure("not_regular_file", "Select a regular CSV or TSV file.") }
        var selectedRoot = stat()
        guard lstat(rootURL.path, &selectedRoot) == 0,
              (selectedRoot.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              try pathGuard.resolve(".").path == rootURL.path else { throw changed() }
        // Start inside the already authorized workspace. An iOS sandbox or
        // selected folder grant need not permit opening the global / directory.
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw DelimitedTable.Failure("source_unavailable", "Cannot open the authorized workspace.") }
        var descriptors: [Int32] = [root]
        var bindings: [Binding] = []
        defer { for descriptor in descriptors.reversed() { _ = close(descriptor) } }
        var openedRoot = stat()
        guard fstat(root, &openedRoot) == 0, sameIdentity(selectedRoot, openedRoot) else { throw changed() }
        var parent = root
        for (index, component) in components.enumerated() {
            try checkCancellation()
            let isFile = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (isFile ? 0 : O_DIRECTORY)
            var selected = stat()
            guard fstatat(parent, component, &selected, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DelimitedTable.Failure("source_unavailable", "The authorized source is unavailable.")
            }
            let child = openat(parent, component, flags)
            guard child >= 0 else { throw DelimitedTable.Failure("source_changed", "A source path component changed or cannot be opened without following links.") }
            descriptors.append(child)
            var opened = stat()
            guard fstat(child, &opened) == 0, sameIdentity(selected, opened),
                  (opened.st_mode & mode_t(S_IFMT)) == mode_t(isFile ? S_IFREG : S_IFDIR) else {
                throw DelimitedTable.Failure("not_regular_file", "Select a regular CSV or TSV file.")
            }
            bindings.append(.init(parent: parent, name: component, child: child, info: opened, isFile: isFile))
            parent = child
        }
        guard let initial = bindings.last?.info, initial.st_size >= 0,
              initial.st_size <= min(pathGuard.maxReadBytes, maximumFileBytes) else {
            throw DelimitedTable.Failure("file_size_limit", "CSV/TSV reads are limited to 10 MiB or the existing workspace read limit.")
        }
        let handle = FileHandle(fileDescriptor: parent, closeOnDealloc: false)
        var data = Data(); data.reserveCapacity(Int(initial.st_size))
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= Int(initial.st_size) else { throw changed() }
            data.append(chunk)
        }
        guard data.count == Int(initial.st_size) else { throw changed() }
        let digest = FloeDigest.sha256Hex(data)
        if let expectedSHA256, expectedSHA256 != digest {
            throw WorkspaceToolError.conflict(expected: expectedSHA256, actual: digest)
        }
        let probe: ReaderEncodingProbe
        if let encoding {
            guard !ReaderTextCodec.manualChoiceConflictsWithBOM(encoding, sample: data) else {
                throw DelimitedTable.Failure("encoding_conflict", "The selected encoding contradicts the source BOM.")
            }
            let detected = ReaderTextCodec.probe(Data(data.prefix(65_536)))
            probe = .init(encoding: encoding, bomLength: detected?.fromBOM == true ? detected!.bomLength : 0, fromBOM: detected?.fromBOM ?? false)
        } else if data.isEmpty { probe = .init(encoding: .utf8, bomLength: 0, fromBOM: false) }
        else {
            guard let detected = ReaderTextCodec.probe(Data(data.prefix(65_536))) else {
                throw DelimitedTable.Failure("unrecognized_encoding", "The source encoding could not be recognized; select a supported encoding explicitly.")
            }
            probe = detected
        }
        let body = Data(data.dropFirst(probe.bomLength))
        var validator = ReaderTextValidator(encoding: probe.encoding, startOffset: Int64(probe.bomLength), rejectsNUL: true)
        if let offset = validator.consume(body, isLast: true) {
            throw DelimitedTable.Failure("invalid_encoding", "The source is invalid in \(probe.encoding.rawValue) at byte \(offset).")
        }
        guard let text = ReaderTextCodec.decode(body, as: probe.encoding) else {
            throw DelimitedTable.Failure("invalid_encoding", "The complete source could not be decoded without replacement.")
        }
        let source = Source(path: path, resolvedWorkspacePath: relativePath, sha256: digest, byteCount: data.count, encoding: probe.encoding,
                            encodingSelection: encoding != nil ? "explicit" : probe.fromBOM ? "bom" : "detected", bomBytes: probe.bomLength)
        let prepared = try prepare(source, text)
        try checkCancellation()
        var boundRoot = stat()
        guard lstat(rootURL.path, &boundRoot) == 0, sameIdentity(selectedRoot, boundRoot),
              try pathGuard.resolve(".").path == rootURL.path else { throw changed() }
        for binding in bindings {
            var bound = stat(), opened = stat()
            guard fstatat(binding.parent, binding.name, &bound, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(binding.child, &opened) == 0,
                  sameIdentity(binding.info, bound), sameIdentity(binding.info, opened),
                  !binding.isFile || (sameContent(binding.info, bound) && sameContent(binding.info, opened)) else { throw changed() }
        }
        try checkCancellation()
        return prepared
    }
    private static func changed() -> DelimitedTable.Failure {
        .init("source_changed", "The source changed while it was being read. Read the first page again.")
    }
    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
    }
    private static func sameContent(_ lhs: stat, _ rhs: stat) -> Bool {
        #if canImport(Darwin)
        lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        #else
        lhs.st_size == rhs.st_size && lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec && lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec && lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
        #endif
    }
}

import Foundation
import FloeCore

/// One IDE instance owns one guarded workspace. Browser filesystem operations
/// acknowledge writes only after the native atomic save has succeeded.
public actor IDEWorkspaceSession {
    public struct Request: Codable, Sendable {
        public var operation: String
        public var path: String
        public var destination: String?
        public var contentBase64: String?
        public init(operation: String, path: String, destination: String? = nil, contentBase64: String? = nil) {
            self.operation = operation; self.path = path
            self.destination = destination; self.contentBase64 = contentBase64
        }
    }
    public struct Entry: Codable, Sendable {
        public var name: String
        public var directory: Bool
        public var size: Int64
    }
    public struct Response: Codable, Sendable {
        public var contentBase64: String? = nil
        public var entries: [Entry]? = nil
        public var directory: Bool? = nil
        public var size: Int64? = nil
        public var modified: Double? = nil
    }
    private struct Baseline { var sha256: String; var mtime: Double }
    private let files: WorkspaceFileService
    private var baselines: [String: Baseline] = [:]
    private var closed = false
    public static let maximumFileBytes = 4 * 1024 * 1024

    public init(files: WorkspaceFileService) { self.files = files }
    public func close() { closed = true; baselines.removeAll() }

    public func handle(_ request: Request) throws -> Response {
        guard !closed else { throw WorkspaceToolError.invalidArguments("IDE workspace is closed") }
        let path = try Self.relativePath(request.path)
        switch request.operation {
        case "stat":
            let metadata = try files.metadata(path)
            let url = try files.guardResolver.resolve(path)
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return Response(directory: directory, size: metadata.size, modified: metadata.mtime * 1000)
        case "list":
            var token: String?
            var entries: [Entry] = []
            repeat {
                let page = try files.listDirectory(path, pageToken: token)
                entries += page.entries.map { Entry(name: $0.name, directory: $0.isDirectory, size: $0.size) }
                guard entries.count <= 10_000 else { throw WorkspaceToolError.tooLarge(limit: 10_000) }
                token = page.nextPageToken
            } while token != nil
            return Response(entries: entries)
        case "read":
            let url = try files.guardResolver.resolve(path)
            let metadata = try files.metadata(path)
            guard metadata.size <= Self.maximumFileBytes else { throw WorkspaceToolError.tooLarge(limit: Self.maximumFileBytes) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard data.count <= Self.maximumFileBytes else { throw WorkspaceToolError.tooLarge(limit: Self.maximumFileBytes) }
            // Search and stat must not replace the original version beneath
            // an open dirty editor. A conflict requires an explicit reopen.
            if baselines[path] == nil {
                baselines[path] = Baseline(sha256: FloeDigest.sha256Hex(data), mtime: metadata.mtime)
            }
            return Response(contentBase64: data.base64EncodedString())
        case "write":
            guard path != ".", let encoded = request.contentBase64,
                  encoded.utf8.count <= (Self.maximumFileBytes + 2) / 3 * 4,
                  let data = Data(base64Encoded: encoded), data.count <= Self.maximumFileBytes,
                  let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceToolError.invalidArguments("IDE writes require a complete UTF-8 text file of at most 4 MiB")
            }
            let outcome: WriteOutcome
            if let baseline = baselines[path] {
                outcome = try files.writeFile(path, content: text, expectedMtime: baseline.mtime, expectedSHA256: baseline.sha256)
            } else {
                // Never overwrite a file the editor has not read.
                outcome = try files.createFile(path, content: text, overwrite: false)
            }
            baselines[path] = Baseline(sha256: outcome.sha256, mtime: outcome.mtime)
            return Response(size: Int64(outcome.bytesWritten), modified: outcome.mtime * 1000)
        case "mkdir":
            guard path != "." else { return Response() }
            try files.createDirectory(path)
            return Response()
        case "rename":
            guard path != ".", let requestedDestination = request.destination else {
                throw WorkspaceToolError.invalidArguments("A file destination is required")
            }
            let destination = try Self.relativePath(requestedDestination)
            guard destination != "." else { throw WorkspaceToolError.invalidArguments("Cannot replace workspace root") }
            try files.move(path, to: destination)
            for key in Array(baselines.keys) where key == path || key.hasPrefix(path + "/") {
                baselines[destination + String(key.dropFirst(path.count))] = baselines.removeValue(forKey: key)
            }
            return Response()
        case "delete":
            guard path != "." else { throw WorkspaceToolError.invalidArguments("Cannot delete workspace root") }
            try files.delete(path, recursive: false)
            baselines.removeValue(forKey: path)
            return Response()
        default:
            throw WorkspaceToolError.invalidArguments("Unsupported IDE filesystem operation")
        }
    }

    /// BrowserFS paths are rooted at its *workspace mount*, never native paths.
    public static func relativePath(_ path: String) throws -> String {
        guard path.utf8.count <= 4096, path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("\0"), !path.contains("\\"),
              !path.split(separator: "/").contains("..") else {
            throw WorkspaceToolError.invalidArguments("Invalid IDE workspace path")
        }
        let relative = String(path.dropFirst())
        return relative.isEmpty ? "." : relative
    }
}

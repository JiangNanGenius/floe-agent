// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Darwin
import FloeCore
import FloeTools
import FloeWorkspace
import FloeGameBuildKit

/// `GameExternalArchiveHostPort` over the App's existing archive decoders.
///
/// ZIP/TAR/TGZ/TBZ2/TXZ use `ArchiveEngine`; 7z uses the existing bounded
/// `WorkspaceArchiveTool`; RAR uses the existing signed CArchive handler. It
/// never starts the Linux guest, creates a second decompressor or mints a
/// random run identity. The authority is a real saved run/conversation, and
/// every request is bounded before the importer can commit a project revision.
struct MainGameExternalArchiveHost: GameExternalArchiveHostPort {
    let root: URL
    let authority: @Sendable () async throws -> GameArchiveRunAuthority
    let compressedHandler: ArchiveCompressedHandler?

    init(root: URL,
         authority: @escaping @Sendable () async throws -> GameArchiveRunAuthority,
         compressedHandler: ArchiveCompressedHandler? = ArchiveCompressedBridge.makeHandler()) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.authority = authority
        self.compressedHandler = compressedHandler
    }

    func capabilities() async -> Set<GameArchiveContainerFormat> {
        var values: Set<GameArchiveContainerFormat> = [
            .zip, .tar, .tarGzip, .tarBzip2, .tarXz, .sevenZip,
        ]
        if compressedHandler != nil { values.insert(.rar) }
        return values
    }

    func extract(_ request: GameExternalArchiveRequest) async throws {
        guard request.maximumBytes > 0, request.maximumEntries > 0 else {
            throw GameExternalArchiveError.limitExceeded("archive bounds must be positive")
        }
        guard request.password == nil else {
            throw GameExternalArchiveError.hostFailed(
                "Password-protected archives are not supported by the reviewed host decoders.")
        }
        let destination = request.destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GameExternalArchiveError.destinationExists
        }
        let archive = request.archiveURL.standardizedFileURL
        let archiveRelative = try relativePath(archive)
        let destinationRelative = try relativePath(destination)
        try requireRegularFile(archive)
        let run: GameArchiveRunAuthority
        do {
            run = try await authority()
        } catch {
            throw GameExternalArchiveError.hostFailed(error.localizedDescription)
        }
        let cancellation = CancellationToken()
        var produced = false
        defer {
            if !produced { try? FileManager.default.removeItem(at: destination) }
        }

        do {
            switch request.format {
            case .zip:
                try await extractNative(format: "zip", archive: archive,
                                        destination: destination, request: request,
                                        cancellation: cancellation)
            case .tar:
                try await extractNative(format: "tar", archive: archive,
                                        destination: destination, request: request,
                                        cancellation: cancellation)
            case .tarGzip:
                try await extractNative(format: "tgz", archive: archive,
                                        destination: destination, request: request,
                                        cancellation: cancellation)
            case .tarBzip2:
                try await extractNative(format: "tbz2", archive: archive,
                                        destination: destination, request: request,
                                        cancellation: cancellation)
            case .tarXz:
                try await extractNative(format: "txz", archive: archive,
                                        destination: destination, request: request,
                                        cancellation: cancellation)
            case .sevenZip:
                try await extract7z(archive: archiveRelative, destination: destinationRelative,
                                    run: run, cancellation: cancellation)
            case .rar:
                try await extractRAR(archive: archiveRelative, destination: destinationRelative,
                                     run: run, cancellation: cancellation)
            }
            try Task.checkCancellation()
            try validateOutput(destination: destination, request: request)
            produced = true
        } catch let error as GameExternalArchiveError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameExternalArchiveError.hostFailed(error.localizedDescription)
        }
    }

    // MARK: - Native engine

    private func extractNative(format: String, archive: URL, destination: URL,
                               request: GameExternalArchiveRequest,
                               cancellation: CancellationToken) async throws {
        let limits = ArchiveLimits(
            maxEntries: request.maximumEntries,
            maxTotalBytes: Int64(request.maximumBytes),
            maxListedEntries: min(500, request.maximumEntries))
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    _ = try ArchiveEngine.extract(format: format, source: archive,
                                                  destination: destination,
                                                  limits: limits,
                                                  cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch let error as ArchiveEngineError {
            switch error {
            case .limitExceeded(let detail):
                throw GameExternalArchiveError.limitExceeded(detail)
            case .conflict(let detail):
                throw GameExternalArchiveError.insecureTree(detail)
            case .corrupt(let detail), .resourceBound(let detail):
                throw GameExternalArchiveError.hostFailed(detail)
            case .outputInsideSource(let path):
                throw GameExternalArchiveError.insecureTree(path)
            case .unsupportedFormat(let value):
                throw GameExternalArchiveError.hostFailed(
                    "Unsupported native archive format: \(value)")
            case .insufficientSpace(let required, let available):
                throw GameExternalArchiveError.hostFailed(
                    "Not enough free space: needs \(required), has \(available)")
            }
        }
    }

    // MARK: - 7z

    private func extract7z(archive: String, destination: String,
                           run: GameArchiveRunAuthority,
                           cancellation: CancellationToken) async throws {
        let environment = WorkspaceToolEnvironment(rootProvider: { [root = root] in root })
        let tool = WorkspaceArchiveTool(environment: environment,
                                        compressedHandler: compressedHandler)
        let context = ToolContext(
            runID: run.runID,
            toolCallID: "game.archive.7z",
            toolIdempotencyKey: UUID().uuidString.lowercased(),
            scope: .local,
            workspaceRootURL: root,
            cancellation: cancellation,
            environmentID: run.environmentID,
            executionBindingGeneration: run.executionBindingGeneration,
            conversationID: run.conversationID)
        let arguments = WorkspaceArchiveTool.Arguments(
            action: "extract", source: archive, destinationDir: destination, format: "7z")
        do {
            _ = try await tool.execute(arguments, context: context)
        } catch let error as WorkspaceToolError {
            switch error {
            case .tooLarge(let limit):
                throw GameExternalArchiveError.limitExceeded(
                    "The existing 7z decoder budget is \(limit) entries or bytes.")
            case .escapesRoot(let path):
                throw GameExternalArchiveError.insecureTree(path)
            case .alreadyExists, .alreadyExistsOverwritable:
                throw GameExternalArchiveError.destinationExists
            default:
                throw GameExternalArchiveError.hostFailed(error.localizedDescription)
            }
        } catch {
            throw mapHostArchiveError(error)
        }
    }

    // MARK: - RAR

    private func extractRAR(archive: String, destination: String,
                            run: GameArchiveRunAuthority,
                            cancellation: CancellationToken) async throws {
        guard let compressedHandler else {
            let available = Array(await capabilities())
            throw GameExternalArchiveError.formatUnavailable(.rar, available: available)
        }
        do {
            _ = try await compressedHandler(ArchiveCompressedRequest(
                action: "extract", format: "rar", source: archive,
                destination: destination, workspaceRoot: root,
                cancellation: cancellation, environmentID: run.environmentID))
        } catch {
            throw mapHostArchiveError(error)
        }
    }

    // MARK: - Bounds and confinement

    private func relativePath(_ url: URL) throws -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != rootPath, path.hasPrefix(rootPath + "/") else {
            throw GameExternalArchiveError.insecureTree(
                "archive path is outside the owned import workspace")
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func requireRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw GameExternalArchiveError.hostFailed(
                "The selected archive is not a regular file.")
        }
    }

    private func validateOutput(destination: URL, request: GameExternalArchiveRequest) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GameExternalArchiveError.hostFailed(
                "Archive extraction produced no destination directory.")
        }
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: keys, options: []) else {
            throw GameExternalArchiveError.hostFailed("The extracted tree could not be enumerated.")
        }
        var entries = 0
        var bytes = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw GameExternalArchiveError.insecureTree(
                    "The archive contains a symbolic link: \(url.lastPathComponent)")
            }
            entries += 1
            guard entries <= request.maximumEntries else {
                throw GameExternalArchiveError.limitExceeded(
                    "Entry count exceeds \(request.maximumEntries).")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw GameExternalArchiveError.insecureTree(
                    "The archive contains a non-regular entry: \(url.lastPathComponent)")
            }
            bytes += values.fileSize ?? 0
            guard bytes <= request.maximumBytes else {
                throw GameExternalArchiveError.limitExceeded(
                    "Uncompressed bytes exceed \(request.maximumBytes).")
            }
        }
    }

    private func mapHostArchiveError(_ error: Error) -> GameExternalArchiveError {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("limit") {
            return .limitExceeded(message)
        }
        if message.localizedCaseInsensitiveContains("unsafe")
            || message.localizedCaseInsensitiveContains("escape") {
            return .insecureTree(message)
        }
        return .hostFailed(message)
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — coordinated, bounded materialization of a system-opened file
// (S5 P3).
//
// The provider URL is read only while its security-scoped access is held.
// NSFileCoordinator asks a document provider to finish downloading before the
// bytes are copied. The copy is streamed (never one in-memory Data), hashed,
// written under the app-owned staging directory and only then gets a durable
// entry record. The original provider bytes are never written, renamed or
// deleted.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CryptoKit
import UniformTypeIdentifiers
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

/// One provider security scope, acquired in the open-URL callback and
/// released exactly once after the copy (or on any early return).
final class DocumentIntakeProviderLease: @unchecked Sendable {
    let url: URL
    private let didAccess: Bool
    private let stateLock = NSLock()
    private var released = false

    init(url: URL) {
        self.url = url
        self.didAccess = url.startAccessingSecurityScopedResource()
    }

    /// Idempotent: the stager and an early-cancelled caller can both release.
    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        released = true
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }

    deinit { release() }
}

enum DocumentIntakeStager {
    /// Runs the blocking coordination/copy away from the main actor using a
    /// scope already acquired by the caller. This is the production path.
    static func stage(
        _ url: URL,
        root: URL,
        limits: DocumentIntakeLimits,
        request: DocumentIntakeStagingRequest,
        lease: DocumentIntakeProviderLease
    ) async throws -> DocumentIntakeStagedInput {
        try await Task.detached(priority: .userInitiated) {
            try stageSynchronously(root: root, limits: limits, request: request, lease: lease)
        }.value
    }

    /// Convenience for focused tests and non-system callers: acquires and
    /// releases the scope inside one operation.
    static func stage(
        _ url: URL,
        root: URL,
        limits: DocumentIntakeLimits,
        request: DocumentIntakeStagingRequest
    ) async throws -> DocumentIntakeStagedInput {
        try await stage(
            url,
            root: root,
            limits: limits,
            request: request,
            lease: DocumentIntakeProviderLease(url: url)
        )
    }

    private static func stageSynchronously(
        root: URL,
        limits: DocumentIntakeLimits,
        request: DocumentIntakeStagingRequest,
        lease: DocumentIntakeProviderLease
    ) throws -> DocumentIntakeStagedInput {
        defer { lease.release() }
        let url = lease.url
        guard url.isFileURL else { throw DocumentIntakeError.unsupportedType }
        guard url.path.utf8.count <= 4_096 else { throw DocumentIntakeError.unsupportedType }

        // Check the provider item before coordination: a coordinator may hand
        // the accessor a resolved URL, which would hide a symbolic link.
        if let original = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey]) {
            guard original.isSymbolicLink != true, original.isAliasFile != true else {
                throw DocumentIntakeError.linkNotAllowed
            }
        }

        var coordinationError: NSError?
        var outcome: Result<DocumentIntakeStagedInput, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinated in
            outcome = Result {
                try copy(coordinated, root: root, limits: limits, request: request)
            }
        }
        if let coordinationError { throw mapReadError(coordinationError) }
        guard let outcome else { throw DocumentIntakeError.accessDenied }
        return try outcome.get()
    }

    private static func copy(
        _ source: URL,
        root: URL,
        limits: DocumentIntakeLimits,
        request: DocumentIntakeStagingRequest
    ) throws -> DocumentIntakeStagedInput {
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
                .fileSizeKey,
                .contentTypeKey,
            ])
        } catch {
            throw mapReadError(error)
        }
        guard values.isRegularFile == true else { throw DocumentIntakeError.notAFile }
        guard values.isSymbolicLink != true, values.isAliasFile != true else {
            throw DocumentIntakeError.linkNotAllowed
        }
        guard let kind = DocumentIntakeKind.classify(
            fileExtension: source.pathExtension,
            contentType: values.contentType
        ) else {
            throw DocumentIntakeError.unsupportedType
        }
        if let size = values.fileSize {
            guard size > 0 else { throw DocumentIntakeError.emptyFile }
            guard Int64(size) <= kind.maximumBytes else {
                throw DocumentIntakeError.tooLarge(kind.maximumBytes)
            }
        }

        let canonicalRoot = root.standardizedFileURL
        // Re-opening one of our own staged/queued copies must never recurse
        // back into the queue.
        guard !DocumentIntakeStorage.isContained(source, in: canonicalRoot) else {
            throw DocumentIntakeError.notAFile
        }

        let stagingRoot = canonicalRoot.appendingPathComponent("staging", isDirectory: true)
        guard DocumentIntakeStorage.isDirectoryNotSymlink(stagingRoot) else {
            throw DocumentIntakeError.queueUnavailable
        }
        let directory = stagingRoot.appendingPathComponent(request.eventID.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw DocumentIntakeError.queueUnavailable
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw DocumentIntakeError.ioFailure
        }
        let activeLock = try makeActiveLock(in: directory, root: canonicalRoot)

        let stagedFileName = DocumentIntakeKind.stagedFileName(
            for: kind,
            originalExtension: source.pathExtension
        )
        let payload: (digest: String, byteCount: Int64)
        do {
            payload = try copyPayload(
                from: source,
                to: directory,
                fileName: stagedFileName,
                maximumBytes: kind.maximumBytes
            )
        } catch {
            // Only this attempt's uncommitted staging directory is removed.
            activeLock.close()
            try? DocumentIntakeStorage.removeOwned(directory, in: canonicalRoot)
            throw error
        }
        guard payload.byteCount > 0 else {
            activeLock.close()
            try? DocumentIntakeStorage.removeOwned(directory, in: canonicalRoot)
            throw DocumentIntakeError.emptyFile
        }

        let record = DocumentIntakeRecord(
            id: request.eventID,
            kind: kind,
            displayName: DocumentIntakeKind.displayName(from: source),
            stagedFileName: stagedFileName,
            byteCount: payload.byteCount,
            sha256: payload.digest,
            contentTypeIdentifier: values.contentType?.identifier,
            plannedRootDocumentID: request.plannedRootDocumentID,
            createdAt: request.receivedAt,
            sceneID: request.sceneID,
            requestSequence: request.requestSequence,
            destinationChoiceRequired: request.destinationChoiceRequired ? true : nil
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            guard data.count <= limits.maximumRecordBytes else {
                throw DocumentIntakeError.ioFailure
            }
            try DocumentIntakeStorage.writeDurably(
                data,
                to: directory.appendingPathComponent("entry.json", isDirectory: false)
            )
            try DocumentIntakeStorage.syncDirectory(directory)
        } catch {
            // The copied payload is valid but its record is not durable yet.
            // Keep the directory so maintenance can recover it; the center
            // reports an explicit failure instead of pretending success.
            activeLock.close()
            throw error
        }
        return DocumentIntakeStagedInput(record: record, directory: directory, activeLock: activeLock)
    }

    /// `.active` is an OS exclusive lock, not a timeout: maintenance can tell
    /// a live staging attempt from a directory abandoned by a killed process.
    private static func makeActiveLock(in directory: URL, root: URL) throws -> DocumentIntakeFileLock {
        let active = directory.appendingPathComponent(".active", isDirectory: false)
        let descriptor = active.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            try? DocumentIntakeStorage.removeOwned(directory, in: root)
            throw DocumentIntakeError.ioFailure
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            try? DocumentIntakeStorage.removeOwned(directory, in: root)
            throw DocumentIntakeError.queueUnavailable
        }
        return DocumentIntakeFileLock(descriptor: descriptor)
    }

    private static func copyPayload(
        from source: URL,
        to directory: URL,
        fileName: String,
        maximumBytes: Int64
    ) throws -> (digest: String, byteCount: Int64) {
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DocumentIntakeError.ioFailure
        }
        let writer: FileHandle
        do { writer = try FileHandle(forWritingTo: destination) }
        catch { throw DocumentIntakeError.ioFailure }
        var writerOpen = true
        defer { if writerOpen { try? writer.close() } }
        let reader: FileHandle
        do { reader = try FileHandle(forReadingFrom: source) }
        catch { throw mapReadError(error) }
        defer { try? reader.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk: Data?
            do { chunk = try reader.read(upToCount: DocumentIntakeStorage.chunkBytes) }
            catch { throw mapReadError(error) }
            guard let chunk, !chunk.isEmpty else { break }
            total += Int64(chunk.count)
            guard total <= maximumBytes else {
                throw DocumentIntakeError.tooLarge(maximumBytes)
            }
            hasher.update(data: chunk)
            do { try writer.write(contentsOf: chunk) }
            catch { throw DocumentIntakeError.ioFailure }
        }
        do {
            try writer.synchronize()
            try writer.close()
            writerOpen = false
            try DocumentIntakeStorage.syncDirectory(directory)
        } catch {
            throw DocumentIntakeError.ioFailure
        }
        return (DocumentIntakeStorage.hex(hasher.finalize()), total)
    }

    private static func mapReadError(_ error: Error) -> DocumentIntakeError {
        if let value = error as? DocumentIntakeError { return value }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .accessDenied
            default:
                return .ioFailure
            }
        }
        return .accessDenied
    }
}
#endif

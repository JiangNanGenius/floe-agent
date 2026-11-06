import Foundation
import CryptoKit
import FloeToolboxCore
import FloeToolboxRemoteFiles

public enum RemoteSaveBackState: Sendable { case saved, savedAfterInvalidation, needsReview }
public struct RemoteSaveBackReceipt: Sendable {
    public let state: RemoteSaveBackState
    public let destination: RemoteFilePath
    public let partial: RemoteFilePath
}
public struct RemoteSaveBackFailure: Error,Sendable {
    public let partial: RemoteFilePath
    public let commitAttempted: Bool
}
/// The editor keeps its own existing local document/undo owner. This object owns only the
/// remote revision and save-back transaction; closing a file panel does not discard edits.
public actor RemoteEditorSaveBack {
    public nonisolated let path: RemoteFilePath
    private let session: RemoteFileSession
    private let maximumBytes: Int
    private var originalDigest: Data?
    private var originalRevision: RemoteFileRevision?
    private var busy = false, closed = false
    public init(session: RemoteFileSession,path: RemoteFilePath,maximumBytes: Int = 8*1024*1024) throws {
        guard path.isWithin(session.root), (1...16*1024*1024).contains(maximumBytes) else { throw RemoteFileError.limit }
        self.session = session; self.path = path; self.maximumBytes = maximumBytes
    }
    private func check() throws { guard !closed, !Task.isCancelled else { throw RemoteFileError.staleSession } }
    private func readCurrent() async throws -> (Data,RemoteFileRevision) {
        let before = try await session.metadata(path,expected:session.lease)
        guard before.kind == .file, before.revision.byteCount.map({$0 <= maximumBytes}) ?? true else { throw RemoteFileError.limit }
        var bytes = Data()
        while true {
            try check()
            let chunk = try await session.read(path,offset:UInt64(bytes.count),maximumBytes:min(65536,maximumBytes-bytes.count+1),expected:session.lease)
            guard bytes.count+chunk.count <= maximumBytes else { throw RemoteFileError.limit }
            if chunk.isEmpty { break }; bytes += chunk
        }
        let after = try await session.metadata(path,expected:session.lease); try check()
        guard before.revision == after.revision, before.revision.byteCount.map({$0 == bytes.count}) ?? true else { throw RemoteFileError.conflict }
        return (bytes,after.revision)
    }
    public func open() async throws -> Data {
        guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }; try check()
        let (bytes,revision) = try await readCurrent()
        originalDigest = Data(SHA256.hash(data:bytes)); originalRevision = revision; return bytes
    }
    public func save(_ bytes: Data) async throws -> RemoteSaveBackReceipt {
        guard !busy, bytes.count <= maximumBytes, let digest = originalDigest else { throw RemoteFileError.busy }
        guard session.capabilities.isSuperset(of:[.write,.resumeWrite,.rename,.atomicRename]) else { throw RemoteFileError.unsupported }
        busy = true; defer { busy = false }; try check()
        let (remote,revision) = try await readCurrent()
        guard Data(SHA256.hash(data:remote)) == digest, originalRevision.map({$0 == revision}) ?? true else { throw RemoteFileError.conflict }
        let partial = try path.parent.appending(".floe-edit-"+UUID().uuidString+".part")
        var attemptedCommit = false
        do {
            // Empty documents still create a real, exclusive staged file.
            try await session.write(partial,offset:0,bytes:Data(bytes.prefix(65536)),createExclusive:true,expected:session.lease)
            var offset = min(bytes.count,65536)
            while offset < bytes.count {
                try check(); let chunk = Data(bytes.dropFirst(offset).prefix(65536))
                try await session.write(partial,offset:UInt64(offset),bytes:chunk,createExclusive:false,expected:session.lease); offset += chunk.count
            }
            let staged = try await session.metadata(partial,expected:session.lease)
            guard staged.revision.byteCount == UInt64(bytes.count) else { throw RemoteFileError.conflict }
            let (latestBytes,latest) = try await readCurrent(); guard latest == revision, Data(SHA256.hash(data:latestBytes)) == digest else { throw RemoteFileError.conflict }; try check()
            attemptedCommit = true
            do { try await session.rename(partial,to:path,replace:true,expected:session.lease) }
            catch RemoteFileError.mutationCompletedAfterInvalidation {
                originalDigest = Data(SHA256.hash(data:bytes)); originalRevision = nil
                return RemoteSaveBackReceipt(state:.savedAfterInvalidation,destination:path,partial:partial)
            }
            originalDigest = Data(SHA256.hash(data:bytes)); originalRevision = nil
            return RemoteSaveBackReceipt(state:.saved,destination:path,partial:partial)
        } catch {
            // Keep local editor content and the staged remote path. A lost commit receipt is
            // reviewed before retry; it must not silently overwrite a later remote revision.
            throw RemoteSaveBackFailure(partial:partial,commitAttempted:attemptedCommit)
        }
    }
    public func close() { closed = true }
}

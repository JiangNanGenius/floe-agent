import Foundation
import CryptoKit
import FloeToolboxCore

public enum RemoteTransferConflictPolicy: String, Codable, Sendable { case failIfExists, replace }
public enum RemoteTransferPhase: String, Codable, Sendable {
    case preparing, verifyingPartial, transferring, committing, completed, completedAfterInvalidation, cancelled, failed, needsReview
}
/// Store this through the host's existing job/persistence owner, never the view lifetime.
public struct RemoteTransferCheckpoint: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceMachine: MachineReference
    public let destinationMachine: MachineReference
    public let source: RemoteFilePath
    public let destination: RemoteFilePath
    public let partial: RemoteFilePath
    public let sourceRevision: RemoteFileRevision
    public let completedBytes: UInt64
    public let prefixSHA256: String
}
public struct RemoteTransferSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let phase: RemoteTransferPhase
    public let completedBytes: UInt64
    public let totalBytes: UInt64?
    public let checkpoint: RemoteTransferCheckpoint?
}
public typealias RemoteTransferObserver = @Sendable (RemoteTransferSnapshot) async -> Void

/// Bounded streaming copy for adapters with ranged IO and no-overwrite rename.
/// SCP and whole-file-only mount adapters use their native transfer job instead of advertising these capabilities.
public actor RemoteFileTransfer {
    public nonisolated let id: UUID
    private var running = false
    public private(set) var snapshot: RemoteTransferSnapshot
    public init(id: UUID = UUID()) {
        self.id = id
        snapshot = RemoteTransferSnapshot(id:id,phase:.preparing,completedBytes:0,totalBytes:nil,checkpoint:nil)
    }
    private func publish(_ phase: RemoteTransferPhase, bytes: UInt64, total: UInt64?,
                         checkpoint: RemoteTransferCheckpoint?, observer: RemoteTransferObserver) async {
        snapshot = RemoteTransferSnapshot(id:id,phase:phase,completedBytes:bytes,totalBytes:total,checkpoint:checkpoint)
        await observer(snapshot)
    }
    private func existing(_ path: RemoteFilePath, on session: RemoteFileSession) async throws -> RemoteFileEntry? {
        do { return try await session.metadata(path,expected:session.lease) }
        catch RemoteFileError.notFound { return nil }
    }
    public func copy(source: RemoteFileSession, path: RemoteFilePath, destination: RemoteFileSession,
                     to target: RemoteFilePath, conflict: RemoteTransferConflictPolicy = .failIfExists,
                     resume: RemoteTransferCheckpoint? = nil, maximumBytes: UInt64 = 32*1024*1024*1024,
                     observer: @escaping RemoteTransferObserver = { _ in }) async throws -> RemoteTransferSnapshot {
        guard !running else { throw RemoteFileError.busy }
        guard maximumBytes > 0, maximumBytes <= 1024*1024*1024*1024 else { throw RemoteFileError.limit }
        running = true; defer { running = false }
        var bytes: UInt64 = 0, total: UInt64?, checkpoint: RemoteTransferCheckpoint?
        var phase = RemoteTransferPhase.preparing
        var commitAttempted = false
        do {
            try Task.checkCancellation()
            guard source.capabilities.isSuperset(of:[.read,.resumeRead]),
                  destination.capabilities.isSuperset(of:[.write,.resumeWrite,.rename]),
                  source.machine != destination.machine || path != target else { throw RemoteFileError.unsupported }
            let original = try await source.metadata(path,expected:source.lease)
            guard original.kind == .file || original.kind == .unknown else { throw RemoteFileError.unsupported }
            total = original.revision.byteCount
            guard total.map({ $0 <= maximumBytes }) ?? true else { throw RemoteFileError.limit }
            let priorDestination = try await existing(target,on:destination)
            if priorDestination != nil {
                guard conflict == .replace else { throw RemoteFileError.conflict }
                guard priorDestination?.kind == .file, destination.capabilities.contains(.atomicRename) else { throw RemoteFileError.unsupported }
            }
            let partial: RemoteFilePath
            var digest = SHA256()
            if let resume {
                guard destination.capabilities.isSuperset(of:[.read,.resumeRead]) else { throw RemoteFileError.unsupported }
                guard resume.id == id, resume.sourceMachine == source.machine, resume.destinationMachine == destination.machine,
                      resume.source == path, resume.destination == target, resume.partial.parent == target.parent,
                      resume.partial.name == ".floe-\(id.uuidString.lowercased()).part",
                      resume.sourceRevision == original.revision, resume.completedBytes <= maximumBytes,
                      original.revision.entityTag != nil || (original.revision.byteCount != nil && original.revision.modifiedAt != nil),
                      original.revision.byteCount.map({ resume.completedBytes <= $0 }) ?? false else { throw RemoteFileError.conflict }
                partial = resume.partial
                let partialInfo = try await destination.metadata(partial,expected:destination.lease)
                guard partialInfo.kind == .file, partialInfo.revision.byteCount == resume.completedBytes else { throw RemoteFileError.conflict }
                phase = .verifyingPartial
                await publish(phase,bytes:0,total:total,checkpoint:resume,observer:observer)
                var remoteDigest = SHA256()
                while bytes < resume.completedBytes {
                    try Task.checkCancellation()
                    let count = Int(min(65536,resume.completedBytes-bytes))
                    let left = try await source.read(path,offset:bytes,maximumBytes:count,expected:source.lease)
                    let right = try await destination.read(partial,offset:bytes,maximumBytes:count,expected:destination.lease)
                    guard !left.isEmpty, left.count == right.count else { throw RemoteFileError.conflict }
                    digest.update(data:left); remoteDigest.update(data:right); bytes += UInt64(left.count)
                }
                guard Self.prefixHash(digest) == resume.prefixSHA256,
                      Self.hex(remoteDigest.finalize()) == resume.prefixSHA256 else { throw RemoteFileError.conflict }
                checkpoint = resume
            } else {
                partial = try target.parent.appending(".floe-\(id.uuidString.lowercased()).part")
                try await destination.write(partial,offset:0,bytes:Data(),createExclusive:true,expected:destination.lease)
            }
            func makeCheckpoint() -> RemoteTransferCheckpoint {
                RemoteTransferCheckpoint(id:id,sourceMachine:source.machine,destinationMachine:destination.machine,
                    source:path,destination:target,partial:partial,sourceRevision:original.revision,
                    completedBytes:bytes,prefixSHA256:Self.prefixHash(digest))
            }
            checkpoint = makeCheckpoint(); phase = .transferring
            await publish(phase,bytes:bytes,total:total,checkpoint:checkpoint,observer:observer)
            while true {
                try Task.checkCancellation()
                let count = Int(min(65536,maximumBytes-bytes+1))
                let chunk = try await source.read(path,offset:bytes,maximumBytes:count,expected:source.lease)
                if chunk.isEmpty { break }
                guard UInt64(chunk.count) <= maximumBytes-bytes,
                      total.map({ bytes+UInt64(chunk.count) <= $0 }) ?? true else { throw RemoteFileError.limit }
                try await destination.write(partial,offset:bytes,bytes:chunk,createExclusive:false,expected:destination.lease)
                bytes += UInt64(chunk.count); digest.update(data:chunk); checkpoint = makeCheckpoint()
                await publish(phase,bytes:bytes,total:total,checkpoint:checkpoint,observer:observer)
            }
            let currentSource = try await source.metadata(path,expected:source.lease)
            guard currentSource.revision == original.revision, total.map({ bytes == $0 }) ?? true,
                  try await existing(target,on:destination) == priorDestination else { throw RemoteFileError.conflict }
            phase = .committing
            await publish(phase,bytes:bytes,total:total,checkpoint:checkpoint,observer:observer)
            try Task.checkCancellation()
            commitAttempted = true
            try await destination.rename(partial,to:target,replace:priorDestination != nil,expected:destination.lease)
            await publish(.completed,bytes:bytes,total:total,checkpoint:nil,observer:observer)
            return snapshot
        } catch {
            let final: RemoteTransferPhase
            if commitAttempted, error as? RemoteFileError == .mutationCompletedAfterInvalidation { final = .completedAfterInvalidation; checkpoint = nil }
            else if commitAttempted, !Self.definitelyRejected(error) { final = .needsReview }
            else if error is CancellationError || Task.isCancelled { final = .cancelled }
            else { final = .failed }
            await publish(final,bytes:bytes,total:total,checkpoint:checkpoint,observer:observer)
            if final == .completedAfterInvalidation { return snapshot }
            throw error
        }
    }
    private static func hex(_ value: SHA256.Digest) -> String { value.map { String(format:"%02x",$0) }.joined() }
    private static func prefixHash(_ value: SHA256) -> String { let copy = value; return hex(copy.finalize()) }
    private static func definitelyRejected(_ error: any Error) -> Bool {
        switch error as? RemoteFileError {
        case .denied,.unsupported,.notFound,.conflict,.invalidPath,.outsideRoot,.staleSession,.authenticationFailed,.busy,.serverStatus: true
        default: false
        }
    }
}

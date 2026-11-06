import Foundation
import CryptoKit
import Testing
import FloeToolboxCore
import FloeToolboxRemoteFiles
@testable import FloeToolboxFileTransports

private actor MemoryFiles: RemoteFileBackend {
    nonisolated let capabilities: Set<RemoteFileCapability> = [.list,.read,.write,.resumeRead,.resumeWrite,.rename,.atomicRename,.createDirectory,.delete]
    var files: [RemoteFilePath:Data]
    var failWrites = false
    var invalidateAfterRename = false
    init(_ files: [RemoteFilePath:Data]) { self.files = files }
    func set(_ path: RemoteFilePath,_ data: Data) { files[path] = data }
    func failNextWrites() { failWrites = true }
    func invalidateRename() { invalidateAfterRename = true }
    func list(_ path: RemoteFilePath) throws -> [RemoteFileEntry] { try files.keys.filter {$0.parent == path}.map { try metadata($0) } }
    func metadata(_ path: RemoteFilePath) throws -> RemoteFileEntry {
        guard let bytes = files[path] else { throw RemoteFileError.notFound }
        return RemoteFileEntry(path:path,kind:.file,revision:RemoteFileRevision(entityTag:Data(SHA256.hash(data:bytes)).base64EncodedString(),byteCount:UInt64(bytes.count)))
    }
    func read(_ path: RemoteFilePath,offset: UInt64,maximumBytes: Int) throws -> Data { guard let bytes = files[path], offset <= bytes.count else { throw RemoteFileError.notFound }; return Data(bytes.dropFirst(Int(offset)).prefix(maximumBytes)) }
    func write(_ path: RemoteFilePath,offset: UInt64,bytes: Data,createExclusive: Bool) throws {
        if failWrites { throw RemoteFileError.serverStatus(4) }
        if createExclusive, files[path] != nil { throw RemoteFileError.conflict }
        var value = files[path] ?? Data(); guard offset <= value.count else { throw RemoteFileError.conflict }
        let start = Int(offset), end = start+bytes.count
        if end > value.count { value.append(Data(repeating:0,count:end-value.count)) }; value.replaceSubrange(start..<end,with:bytes); files[path] = value
    }
    func createDirectory(_ path: RemoteFilePath) {}
    func rename(_ source: RemoteFilePath,to destination: RemoteFilePath,replace: Bool) throws {
        guard let bytes = files[source], replace || files[destination] == nil else { throw RemoteFileError.conflict }
        files[destination] = bytes; files.removeValue(forKey:source)
        if invalidateAfterRename { throw RemoteFileError.mutationCompletedAfterInvalidation }
    }
    func delete(_ path: RemoteFilePath,directory: Bool) { files.removeValue(forKey:path) }
    func resolve(_ path: RemoteFilePath) -> RemoteFilePath { path }
    func close() {}
}
private actor QueueStore: TransferQueueRepository {
    var value: TransferQueueState?
    var saves = 0
    let reject: Bool
    init(_ value: TransferQueueState? = nil,reject: Bool = false) { self.value = value; self.reject = reject }
    func load(ownerID: UUID) -> TransferQueueState? { value }
    func save(_ state: TransferQueueState,expectedRevision: UInt64) throws {
        guard !reject, expectedRevision == (value?.revision ?? 0) else { throw ToolboxError.revisionConflict }
        value = state; saves += 1
    }
}
private func fileSession(owner: UUID,machine: MachineReference,backend: MemoryFiles) throws -> RemoteFileSession {
    try RemoteFileSession(lease:SessionLease(ownerID:owner),machine:machine,root:RemoteFilePath("/"),backend:backend,authorize:{ _ in true })
}
@Test func transferQueuePersistsBeforeExecutionAndRecoversWithoutWriteReplay() async throws {
    let owner = UUID(), sourceID = MachineReference.temporary(connectionID:UUID()), targetID = MachineReference.temporary(connectionID:UUID())
    let sourcePath = try RemoteFilePath("/source"), target = try RemoteFilePath("/target")
    let bytes = Data(repeating:33,count:200000), source = MemoryFiles([sourcePath:bytes]), destination = MemoryFiles([:]), store = QueueStore()
    let sourceSession = try fileSession(owner:owner,machine:sourceID,backend:source), targetSession = try fileSession(owner:owner,machine:targetID,backend:destination)
    let queue = RemoteTransferQueue(ownerID:owner,repository:store,resolve:{ _,_ in #expect(await store.saves >= 2); return TransferSessionPair(source:sourceSession,destination:targetSession) })
    let request = RemoteTransferRequest(sourceMachine:sourceID,destinationMachine:targetID,source:sourcePath,destination:target)
    let id = try await queue.enqueue(request)
    for _ in 0..<200 { if await queue.snapshot().entries.first?.phase == .completed { break }; try await Task.sleep(for:.milliseconds(5)) }
    #expect(await queue.snapshot().entries.first?.phase == .completed)
    #expect(await destination.files[target] == bytes)
    await queue.close()
    var interrupted = TransferQueueState(ownerID:owner,revision:5)
    interrupted.entries = [TransferQueueEntry(id:id,request:request,phase:.running,transfer:nil,resumeCheckpoint:nil,attempt:UUID())]
    let restored = RemoteTransferQueue(ownerID:owner,repository:QueueStore(interrupted),resolve:{ _,_ in Issue.record("interrupted write replayed"); throw RemoteFileError.denied })
    try await restored.restore(); await restored.start()
    #expect(await restored.snapshot().entries.first?.phase == .needsReview); await restored.close()
    let rejected = RemoteTransferQueue(ownerID:owner,repository:QueueStore(reject:true),resolve:{ _,_ in Issue.record("ran before durable enqueue"); throw RemoteFileError.denied })
    await #expect(throws:ToolboxError.revisionConflict) { try await rejected.enqueue(request) }; await rejected.close()
}
@Test func editorSaveBackKeepsOriginalOnConflictAndRecognizesConfirmedLateCommit() async throws {
    let path = try RemoteFilePath("/file"), backend = MemoryFiles([path:Data("original".utf8)]), owner = UUID()
    let session = try fileSession(owner:owner,machine:.temporary(connectionID:UUID()),backend:backend)
    let editor = try RemoteEditorSaveBack(session:session,path:path)
    #expect(try await editor.open() == Data("original".utf8))
    await backend.set(path,Data("external".utf8))
    await #expect(throws:RemoteFileError.conflict) { try await editor.save(Data("my edit".utf8)) }
    #expect(await backend.files[path] == Data("external".utf8))
    _ = try await editor.open(); await backend.invalidateRename()
    let result = try await editor.save(Data("confirmed edit".utf8))
    #expect(result.state == .savedAfterInvalidation)
    #expect(await backend.files[path] == Data("confirmed edit".utf8))
}
@Test func mountedBackendBoundsPagesPathsAndNeverPretendsWholeFileWriteCanResume() async throws {
    let io = HostMountFileIO(page:{ path,cursor,_ in
        let name = cursor == nil ? "first" : "second"
        return HostMountPage(entries:[RemoteFileEntry(path:try path.appending(name),kind:.file)],nextCursor:"repeated")
    },metadata:{ RemoteFileEntry(path:$0,kind:.file) },read:{ _,_,_ in Data(repeating:7,count:100) },writeWhole:{ _,_,_ in })
    let backend = try HostMountFileBackend(root:RemoteFilePath("/share"),windowsNames:true,io:io)
    #expect(!backend.capabilities.contains(.resumeWrite) && !backend.capabilities.contains(.write))
    await #expect(throws:RemoteFileError.malformedResponse) { try await backend.list(RemoteFilePath("/share")) }
    await #expect(throws:RemoteFileError.invalidPath) { try await backend.read(RemoteFilePath("/share/a\\..\\secret"),offset:0,maximumBytes:100) }
    await #expect(throws:RemoteFileError.limit) { try await backend.read(RemoteFilePath("/share/a"),offset:0,maximumBytes:2) }
    await backend.close()
}

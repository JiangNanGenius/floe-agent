import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxRemoteFiles

private actor MemoryFiles: RemoteFileBackend {
    nonisolated let capabilities: Set<RemoteFileCapability> = [.list,.read,.write,.createDirectory,.rename,.delete,.resolveLink,.resumeRead,.resumeWrite,.atomicRename]
    private var files: [String:Data] = [:]
    private var directories: Set<String> = ["/files"]
    private var versions: [String:Int] = [:]
    private(set) var maximumRead = 0
    private(set) var writes = 0
    private(set) var reads = 0
    var escapingLink = false
    var injectedChild = false
    private let renameGate: OperationGate?
    private let loseRenameReply: Bool
    init(renameGate: OperationGate? = nil, loseRenameReply: Bool = false) { self.renameGate = renameGate; self.loseRenameReply = loseRenameReply }
    func seed(_ path: String, _ bytes: Data) { files[path] = bytes; versions[path,default:0] += 1 }
    func value(_ path: String) -> Data? { files[path] }
    func escape() { escapingLink = true }
    func poison() { injectedChild = true }
    func list(_ path: RemoteFilePath) throws -> [RemoteFileEntry] {
        if injectedChild { return [RemoteFileEntry(path:try RemoteFilePath("/elsewhere/file"),kind:.file)] }
        return try files.keys.filter { try RemoteFilePath($0).parent == path }.map { try metadata(RemoteFilePath($0)) }
    }
    func metadata(_ path: RemoteFilePath) throws -> RemoteFileEntry {
        if directories.contains(path.value) { return RemoteFileEntry(path:path,kind:.directory) }
        guard let data = files[path.value] else { throw RemoteFileError.notFound }
        return RemoteFileEntry(path:path,kind:.file,revision:RemoteFileRevision(entityTag:String(versions[path.value,default:0]),byteCount:UInt64(data.count),modifiedAt:Date(timeIntervalSince1970:100)))
    }
    func read(_ path: RemoteFilePath, offset: UInt64, maximumBytes: Int) throws -> Data {
        reads += 1; maximumRead = max(maximumRead,maximumBytes)
        guard let data = files[path.value], offset <= UInt64(data.count) else { throw RemoteFileError.notFound }
        return Data(data.dropFirst(Int(offset)).prefix(maximumBytes))
    }
    func write(_ path: RemoteFilePath, offset: UInt64, bytes: Data, createExclusive: Bool) throws {
        if createExclusive, files[path.value] != nil { throw RemoteFileError.conflict }
        var data = files[path.value] ?? Data()
        guard offset <= UInt64(data.count) else { throw RemoteFileError.limit }
        let start = Int(offset), end = start+bytes.count
        if end > data.count { data.append(Data(repeating:0,count:end-data.count)) }
        data.replaceSubrange(start..<end,with:bytes)
        files[path.value] = data; versions[path.value,default:0] += 1; writes += 1
    }
    func createDirectory(_ path: RemoteFilePath) { directories.insert(path.value) }
    func rename(_ source: RemoteFilePath, to destination: RemoteFilePath, replace: Bool) async throws {
        guard let data = files[source.value] else { throw RemoteFileError.notFound }
        guard replace || files[destination.value] == nil else { throw RemoteFileError.conflict }
        files[destination.value] = data; files[source.value] = nil; versions[destination.value,default:0] += 1
        if let renameGate { await renameGate.arrive() }
        if loseRenameReply { throw RemoteFileError.connectionClosed }
    }
    func delete(_ path: RemoteFilePath, directory: Bool) { files[path.value] = nil; directories.remove(path.value) }
    func resolve(_ path: RemoteFilePath) throws -> RemoteFilePath {
        if escapingLink, path.value == "/files/link" { return try RemoteFilePath("/outside/private") }
        return path
    }
    func close() {}
}
private actor OperationGate {
    var arrived = false
    var waiter: CheckedContinuation<Void,Never>?
    var blocked: CheckedContinuation<Void,Never>?
    func arrive() async { arrived = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { blocked = $0 } }
    func wait() async { if !arrived { await withCheckedContinuation { waiter = $0 } } }
    func release() { blocked?.resume(); blocked = nil }
}
private func session(_ backend: any RemoteFileBackend, machine: UUID = UUID(),
                     authorize: @escaping RemoteFileAuthorizer = { _ in true }) throws -> RemoteFileSession {
    try RemoteFileSession(lease:SessionLease(ownerID:UUID()),machine:.temporary(connectionID:machine),
                          root:RemoteFilePath("/files"),backend:backend,authorize:authorize)
}
private actor TransferGate {
    var arrived = false
    var waiting: CheckedContinuation<Void,Never>?
    var releaseWaiter: CheckedContinuation<Void,Never>?
    func observe(_ state: RemoteTransferSnapshot) async {
        guard !arrived, state.phase == .transferring, state.completedBytes > 0 else { return }
        arrived = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func wait() async { if !arrived { await withCheckedContinuation { waiting = $0 } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@Test func remotePathsValidateDecodedDataAndComponentRoots() throws {
    #expect(try RemoteFilePath("/files/a/../b").value == "/files/b")
    #expect(try RemoteFilePath("/").parent.value == "/")
    #expect(try !RemoteFilePath("/files-other/a").isWithin(RemoteFilePath("/files")))
    #expect(throws:RemoteFileError.outsideRoot) { try RemoteFilePath("/../../escape") }
    #expect(throws:RemoteFileError.self) { try RemoteFilePath("/files").appending("../x") }
    #expect(throws:RemoteFileError.self) { try JSONDecoder().decode(RemoteFilePath.self,from:Data(#"{"value":"relative"}"#.utf8)) }
}
@Test func fileProtocolsKeepExplicitTransportAndSyncEnvironment() throws {
    let root = try RemoteFilePath("/files")
    let plan = try RemoteFileConnectionPlan(source:.temporary,transport:.ftps,host:"files.example.test",root:root)
    #expect(plan.port == 21 && plan.ftpsMode == .explicit)
    #expect(try RemoteFileConnectionPlan(source:.temporary,transport:.ftps,host:"files.example.test",root:root,ftpsMode:.implicit).port == 990)
    #expect(throws:RemoteFileError.self) { try RemoteFileConnectionPlan(source:.temporary,transport:.sftp,host:"user:password@example.test",root:root) }
    #expect(throws:RemoteFileError.self) { try RemoteSyncPlan(environmentID:"",source:"/a",destination:"/b") }
    let sync = try RemoteSyncPlan(environmentID:"resolved-linux",source:"/a with space",destination:"/b")
    #expect(sync.dryRun && sync.arguments.contains("--dry-run"))
    #expect(sync.arguments.suffix(3) == ["--","/a with space","/b"])
}
@Test func remoteSessionFencesDenialGenerationAndEscapingEntries() async throws {
    let backend = MemoryFiles(), denied = try session(backend,authorize:{ _ in false })
    await #expect(throws:RemoteFileError.denied) { try await denied.write(RemoteFilePath("/files/a"),offset:0,bytes:Data(),createExclusive:true,expected:denied.lease) }
    #expect(await backend.writes == 0)
    let allowed = try session(backend)
    await #expect(throws:RemoteFileError.staleSession) { try await allowed.list(RemoteFilePath("/files"),expected:SessionLease(ownerID:allowed.lease.ownerID)) }
    await backend.poison()
    await #expect(throws:RemoteFileError.outsideRoot) { try await allowed.list(RemoteFilePath("/files"),expected:allowed.lease) }
    await allowed.close()
    await #expect(throws:RemoteFileError.staleSession) { try await allowed.metadata(RemoteFilePath("/files/a"),expected:allowed.lease) }
}
@Test func resolvedSymlinkOutsideSelectedRootIsNotRead() async throws {
    let backend = MemoryFiles(), client = try session(backend)
    await backend.seed("/files/link",Data("unread".utf8)); await backend.escape()
    await #expect(throws:RemoteFileError.outsideRoot) { try await client.read(RemoteFilePath("/files/link"),offset:0,expected:client.lease) }
    #expect(await backend.reads == 0)
}
@Test func streamingTransferStagesAndBoundsIO() async throws {
    let backend = MemoryFiles(), client = try session(backend), content = Data(repeating:65,count:150123)
    await backend.seed("/files/source",content)
    let transfer = RemoteFileTransfer()
    let result = try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,to:RemoteFilePath("/files/output"))
    #expect(result.phase == .completed && result.completedBytes == UInt64(content.count))
    #expect(await backend.value("/files/output") == content)
    #expect(await backend.maximumRead <= 65536)
    #expect(try await client.list(RemoteFilePath("/files"),expected:client.lease).count == 2)
}
@Test func cancelledTransferPreservesOriginalAndCanVerifyThenResume() async throws {
    let backend = MemoryFiles(), client = try session(backend), gate = TransferGate()
    let content = Data(repeating:66,count:180001), original = Data("original".utf8)
    await backend.seed("/files/source",content); await backend.seed("/files/output",original)
    let transfer = RemoteFileTransfer()
    let work = Task { try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,
        to:RemoteFilePath("/files/output"),conflict:.replace,observer:{ await gate.observe($0) }) }
    await gate.wait(); work.cancel(); await gate.release()
    await #expect(throws:(any Error).self) { try await work.value }
    let checkpoint = try #require(await transfer.snapshot.checkpoint)
    #expect(await transfer.snapshot.phase == .cancelled)
    #expect(await backend.value("/files/output") == original)
    #expect(checkpoint.completedBytes == 65536)
    let result = try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,
        to:RemoteFilePath("/files/output"),conflict:.replace,resume:checkpoint)
    #expect(result.phase == .completed)
    #expect(await backend.value("/files/output") == content)
}
@Test func resumeRejectsTamperedPartialWithSameLength() async throws {
    let backend = MemoryFiles(), client = try session(backend), gate = TransferGate(), transfer = RemoteFileTransfer()
    await backend.seed("/files/source",Data(repeating:67,count:160000))
    let work = Task { try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,to:RemoteFilePath("/files/output"),observer:{ await gate.observe($0) }) }
    await gate.wait(); work.cancel(); await gate.release(); _ = try? await work.value
    let checkpoint = try #require(await transfer.snapshot.checkpoint)
    await backend.seed(checkpoint.partial.value,Data(repeating:68,count:Int(checkpoint.completedBytes)))
    await #expect(throws:RemoteFileError.conflict) { try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,to:RemoteFilePath("/files/output"),resume:checkpoint) }
    #expect(await backend.value("/files/output") == nil)
}
@Test func concurrentDestinationChangeIsNotOverwritten() async throws {
    let backend = MemoryFiles(), client = try session(backend), gate = TransferGate(), transfer = RemoteFileTransfer()
    await backend.seed("/files/source",Data(repeating:69,count:70000))
    let work = Task { try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,to:RemoteFilePath("/files/output"),observer:{ await gate.observe($0) }) }
    await gate.wait(); await backend.seed("/files/output",Data("newer".utf8)); await gate.release()
    await #expect(throws:RemoteFileError.conflict) { try await work.value }
    #expect(await backend.value("/files/output") == Data("newer".utf8))
    #expect(await transfer.snapshot.checkpoint != nil)
}
@Test func confirmedCommitSurvivesSessionInvalidationWithoutRetrying() async throws {
    let gate = OperationGate(), backend = MemoryFiles(renameGate:gate), transfer = RemoteFileTransfer()
    let client = try session(backend), bytes = Data("confirmed".utf8)
    await backend.seed("/files/source",bytes)
    let work = Task { try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,to:RemoteFilePath("/files/output")) }
    await gate.wait(); await client.close(); await gate.release()
    let result = try await work.value
    #expect(result.phase == .completedAfterInvalidation && result.checkpoint == nil)
    #expect(await backend.value("/files/output") == bytes)
}
@Test func lostCommitReplyRequiresReviewEvenWhenServerAppliedIt() async throws {
    let backend = MemoryFiles(loseRenameReply:true), transfer = RemoteFileTransfer(), client = try session(backend)
    await backend.seed("/files/source",Data("applied".utf8))
    await #expect(throws:RemoteFileError.connectionClosed) { try await transfer.copy(source:client,path:RemoteFilePath("/files/source"),destination:client,to:RemoteFilePath("/files/output")) }
    #expect(await transfer.snapshot.phase == .needsReview)
    #expect(await backend.value("/files/output") == Data("applied".utf8))
}

private actor ScriptedSFTP: RemoteFileByteChannel {
    var bytes: Data
    let fragment: Int
    private(set) var closed = false
    init(_ bytes: Data, fragment: Int = 65536) { self.bytes = bytes; self.fragment = fragment }
    func send(_ bytes: Data) {}
    func receive(maximumBytes: Int) -> Data {
        let data = Data(bytes.prefix(min(maximumBytes,fragment))); bytes.removeFirst(data.count); return data
    }
    func close() { closed = true }
}
private func word(_ value: UInt32) -> Data { Data([UInt8(truncatingIfNeeded:value >> 24),UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)]) }
private func frame(_ payload: Data) -> Data { word(UInt32(payload.count))+payload }
private let hello = frame(Data([2])+word(3))
@Test func sftpChecksServerFailureInsteadOfReportingMutationSuccess() async throws {
    let failure = frame(Data([101])+word(1)+word(3)+word(0)+word(0))
    let channel = ScriptedSFTP(hello+failure,fragment:1), backend = try await SFTPRemoteFileBackend.connect(channel:channel)
    await #expect(throws:RemoteFileError.denied) { try await backend.createDirectory(RemoteFilePath("/test")) }
    await backend.close(); #expect(await channel.closed)
}
@Test func sftpRejectsWrongCorrelationAndOversizedFrames() async throws {
    let channel = ScriptedSFTP(hello+frame(Data([101])+word(99)+word(0)+word(0)+word(0)))
    let backend = try await SFTPRemoteFileBackend.connect(channel:channel)
    await #expect(throws:RemoteFileError.malformedResponse) { try await backend.delete(RemoteFilePath("/test"),directory:false) }
    #expect(await channel.closed)
    let large = ScriptedSFTP(word(0x7fffffff))
    await #expect(throws:RemoteFileError.limit) { try await SFTPRemoteFileBackend.connect(channel:large) }
    #expect(await large.closed)
}
@Test func failedSFTPHandleCloseFencesChannelInsteadOfLeakingMoreHandles() async throws {
    let handle = frame(Data([102])+word(1)+word(1)+Data([42]))
    let content = frame(Data([103])+word(2)+word(2)+Data("ok".utf8))
    let failure = frame(Data([101])+word(3)+word(3)+word(0)+word(0))
    let channel = ScriptedSFTP(hello+handle+content+failure), backend = try await SFTPRemoteFileBackend.connect(channel:channel)
    await #expect(throws:RemoteFileError.denied) { try await backend.read(RemoteFilePath("/file"),offset:0,maximumBytes:2) }
    #expect(await channel.closed)
    await #expect(throws:RemoteFileError.connectionClosed) { try await backend.metadata(RemoteFilePath("/another")) }
}
private actor PendingSFTP: RemoteFileByteChannel {
    var initialized = false
    var waiting = false
    var result: CheckedContinuation<Data,any Error>?
    var observer: CheckedContinuation<Void,Never>?
    private(set) var closeCount = 0
    func send(_ bytes: Data) {}
    func receive(maximumBytes: Int) async throws -> Data {
        if !initialized { initialized = true; return hello }
        return try await withCheckedThrowingContinuation { result = $0; waiting = true; observer?.resume(); observer = nil }
    }
    func wait() async { if !waiting { await withCheckedContinuation { observer = $0 } } }
    func close() { closeCount += 1; result?.resume(throwing:RemoteFileError.connectionClosed); result = nil }
}
@Test func cancellingSFTPClosesOnlyItsChannelAndUnblocksPendingRead() async throws {
    let channel = PendingSFTP(), backend = try await SFTPRemoteFileBackend.connect(channel:channel)
    let work = Task { try await backend.metadata(RemoteFilePath("/pending")) }
    await channel.wait(); work.cancel()
    await #expect(throws:RemoteFileError.connectionClosed) { try await work.value }
    await backend.close(); #expect(await channel.closeCount == 1)
}

#if os(macOS)
import Darwin
/// Real OpenSSH server over local pipes: protocol qualification, without accounts or remote machines.
private actor OpenSSHFixture: RemoteFileByteChannel {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    private var closed = false
    init(root: URL) throws {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/libexec/sftp-server")
        process.arguments = ["-d",root.path]; process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice; process.currentDirectoryURL = root
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    func send(_ bytes: Data) throws { guard !closed else { throw RemoteFileError.connectionClosed }; try input.write(contentsOf:bytes) }
    func receive(maximumBytes: Int) async throws -> Data {
        let descriptor = output.fileDescriptor
        return try await Task.detached {
            var ready = pollfd(fd:descriptor,events:Int16(POLLIN),revents:0)
            guard Darwin.poll(&ready,1,3000) > 0 else { throw RemoteFileError.connectionClosed }
            var buffer = [UInt8](repeating:0,count:maximumBytes)
            let count = Darwin.read(descriptor,&buffer,buffer.count)
            guard count >= 0 else { throw RemoteFileError.connectionClosed }
            return Data(buffer.prefix(count))
        }.value
    }
    func close() {
        guard !closed else { return }; closed = true
        try? input.close(); if process.isRunning { process.terminate() }; process.waitUntilExit(); try? output.close()
    }
}
@Test func sftpInteroperatesWithLocalOpenSSHIncludingStagedTransfer() async throws {
    var repository = URL(fileURLWithPath:#filePath)
    for _ in 0..<6 { repository.deleteLastPathComponent() }
    let root = repository.appendingPathComponent("Local/Scratch/toolbox-sftp-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let channel = try OpenSSHFixture(root:root)
    do {
        let backend = try await SFTPRemoteFileBackend.connect(channel:channel)
        let directory = try await backend.resolve(RemoteFilePath(root.path))
        let source = try directory.appending("中文 source.bin"), destination = try directory.appending("copy.bin")
        let bytes = Data((0..<150001).map { UInt8(truncatingIfNeeded:$0) })
        try await backend.write(source,offset:0,bytes:Data(bytes.prefix(65536)),createExclusive:true)
        try await backend.write(source,offset:65536,bytes:Data(bytes.dropFirst(65536)),createExclusive:false)
        #expect(try await backend.read(source,offset:17,maximumBytes:1024) == Data(bytes.dropFirst(17).prefix(1024)))
        #expect(try await backend.list(directory).contains { $0.path == source && $0.revision.byteCount == UInt64(bytes.count) })
        let client = try RemoteFileSession(lease:SessionLease(ownerID:UUID()),machine:.temporary(connectionID:UUID()),root:directory,backend:backend,authorize:{ _ in true })
        let result = try await RemoteFileTransfer().copy(source:client,path:source,destination:client,to:destination)
        #expect(result.phase == .completed)
        #expect(try Data(contentsOf:URL(fileURLWithPath:destination.value)) == bytes)
        #expect(backend.capabilities.contains(.atomicRename))
        let replacement = Data(repeating:90,count:bytes.count)
        try await backend.write(source,offset:0,bytes:replacement,createExclusive:false)
        _ = try await RemoteFileTransfer().copy(source:client,path:source,destination:client,to:destination,conflict:.replace)
        #expect(try Data(contentsOf:URL(fileURLWithPath:destination.value)) == replacement)
        let folder = try directory.appending("folder")
        try await client.createDirectory(folder,expected:client.lease)
        try await client.delete(folder,directory:true,expected:client.lease)
        try await client.delete(source,directory:false,expected:client.lease)
        await #expect(throws:RemoteFileError.notFound) { try await client.metadata(source,expected:client.lease) }
        await client.close()
    } catch { await channel.close(); throw error }
    await channel.close()
}
#endif

import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOSSH
import FloeToolboxSSH
import FloeToolboxRemoteFiles
import FloeSSH
import FloePersistence
import FloeCore

@Test func binaryChildPreservesQueuedFinalBytesWithoutStderrAndClosesOnlyChild() async throws {
    let child = try await NIOAsyncTestingChannel(channelInitializer:{ _ in }), parent = try await NIOAsyncTestingChannel(channelInitializer:{ _ in })
    let transport = try await SSHRemoteFileByteChannel.open { initialize in
        try await initialize(child).get(); return child
    }
    try await child.writeInbound(SSHChannelData(type:.stdErr,data:.byteBuffer(ByteBuffer(string:"synthetic stderr"))))
    try await child.writeInbound(SSHChannelData(type:.channel,data:.byteBuffer(ByteBuffer(bytes:[0,255,1,2,3]))))
    #expect(try await transport.receive(maximumBytes:2) == Data([0,255]))
    try await child.close()
    #expect(try await transport.receive(maximumBytes:8) == Data([1,2,3]))
    await #expect(throws:RemoteFileError.connectionClosed) { try await transport.receive(maximumBytes:8) }
    await transport.close(); #expect(parent.isActive == false)
    // The unrelated parent is still open and can be activated, proving child close did not own it.
    try await parent.connect(to:.init(ipAddress:"127.0.0.1",port:22)); #expect(parent.isActive)
    _ = try await parent.finish(); _ = try await child.finish(acceptAlreadyClosed:true)
}
@Test func binaryChildCancellationClosesPendingReadAndBoundedWrite() async throws {
    let child = try await NIOAsyncTestingChannel(channelInitializer:{ _ in })
    let transport = try await SSHRemoteFileByteChannel.open { initialize in try await initialize(child).get(); return child }
    try await transport.send(Data([0,254,5]))
    let sent = try #require(try await child.readOutbound(as:SSHChannelData.self))
    if case .byteBuffer(let bytes) = sent.data { #expect(Array(bytes.readableBytesView) == [0,254,5]) } else { Issue.record("nonbinary SSH output") }
    let reading = Task { try await transport.receive(maximumBytes:16) }
    try await Task.sleep(for:.milliseconds(20)); reading.cancel()
    await #expect(throws:(any Error).self) { try await reading.value }
    await transport.close(); _ = try await child.finish(acceptAlreadyClosed:true)
}

private enum SyntheticCredentialFailure: Error { case unavailable }
@Test func temporarySSHPolicyDoesNotPersistProfileOnAuthenticationFailure() async throws {
    let database = try DatabaseManager.inMemory(), store = RemoteHostStore(database:database)
    try await database.migrate()
    let service = SSHConnectionService(hostStore:store)
    let profile = RemoteHostProfile(displayName:"Synthetic temporary",address:"127.0.0.1",port:22,user:"fixture",
        auth:.password(SecretReference(keychainAccount:"synthetic-reference",synchronizable:false)))
    await #expect(throws:(any Error).self) { try await service.connectTemporary(profile:profile,credentialResolver:{ _ in throw SyntheticCredentialFailure.unavailable },hostKeyDecision:{ _ in false }) }
    #expect(try await store.host(id:profile.id) == nil)
    await #expect(throws:(any Error).self) { try await service.connect(profile:profile,credentialResolver:{ _ in throw SyntheticCredentialFailure.unavailable },hostKeyDecision:{ _ in false }) }
    #expect(try await store.host(id:profile.id) != nil)
}

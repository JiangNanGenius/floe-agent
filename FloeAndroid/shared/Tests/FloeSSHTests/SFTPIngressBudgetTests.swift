// SPDX-License-Identifier: MPL-2.0
import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import FloeSSH

@Suite("SFTP inbound transport budgets")
struct SFTPIngressBudgetTests {
    @Test @MainActor
    func slowConsumerOverflowClosesChannelAndReportsFailure() async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(2))
        let channel = EmbeddedChannel(handler: SFTPByteChannelHandler(continuation: continuation))
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        #expect(channel.isActive)
        for value in 0..<3 {
            _ = try channel.writeInbound(ByteBuffer(bytes: [UInt8(value)]))
        }
        #expect(!channel.isActive)
        var received: [Data] = []
        var failure: SSHSFTPError?
        do {
            for try await chunk in stream { received.append(chunk) }
        } catch let error as SSHSFTPError {
            failure = error
        }
        #expect(received == [Data([0]), Data([1])])
        #expect(failure == .protocolFailure)
    }

    @Test @MainActor
    func oversizedInboundChunkIsRejectedBeforeQueueing() async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8))
        let channel = EmbeddedChannel(handler: SFTPByteChannelHandler(continuation: continuation))
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        _ = try channel.writeInbound(ByteBuffer(repeating: 0, count: 256 * 1024 + 5))
        #expect(!channel.isActive)
        var count = 0
        var failure: SSHSFTPError?
        do {
            for try await _ in stream { count += 1 }
        } catch let error as SSHSFTPError {
            failure = error
        }
        #expect(count == 0)
        #expect(failure == .protocolFailure)
    }
}

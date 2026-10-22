// Floe integration addition — SPDX-License-Identifier: Apache-2.0
import Foundation

/// Cancellation of AsyncThrowingStream.next() does not join its producer.
/// Owners must join inference before reusing a non-thread-safe model or
/// releasing the process-wide reservation backing that model.
public struct SpeechStreamSession<Chunk: Sendable>: Sendable {
    public let stream: AsyncThrowingStream<Chunk, Error>
    private let producer: Task<Void, Never>
    public init(stream: AsyncThrowingStream<Chunk, Error>, producer: Task<Void, Never>) {
        self.stream = stream
        self.producer = producer
    }
    public func waitForCompletion() async { await producer.value }
    public func cancelAndWait() async { producer.cancel(); await producer.value }
}

// FloeProviders — Lossless bounded audio chunk channel.
//
// SPDX-License-Identifier: MPL-2.0
//
// Demand-driven producer/consumer handoff for streamed PCM. `send` AWAITS
// while the buffer is full, so backpressure propagates all the way to the
// socket read (or the WebSocket receive): NO chunk is ever dropped under a
// slow consumer (settled no-drop audio rule). When the consumer's task is
// cancelled the channel closes: parked senders wake and throw, attached
// producer tasks are cancelled, and queued chunks can never restart playback.
//
// Every condition check and waiter registration happens inside ONE
// synchronous critical section (`withLock`), and each park path re-checks its
// condition atomically inside the continuation body — so a drain/enqueue
// racing between "observe full/empty" and "register waiter" can never strand
// either side. `slotCapacity` AND `byteCapacity` both gate the async send.
//
// The Apple offline-write path needs a synchronous producer (delegate
// callbacks). It uses `sendBounded`: handoff, enqueue, or — past
// `byteCapacity` — an explicit `streamTruncated` close. Lossless up to the
// documented cap; never silent loss.
//
// NSLock is @noasync under Swift 6: every use goes through the synchronous
// `withLock` helper, and no lock is held across a suspension point (values
// and continuations are staged under the lock and resumed after unlock).

import Foundation
import FloeCore

public final class TTSAudioChunkStream: AsyncSequence, Sendable {
    public typealias Element = TTSAudioChunk

    fileprivate final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [TTSAudioChunk] = []
        private var byteCount = 0
        private let slotCapacity: Int
        private let byteCapacity: Int
        private var closed = false
        private var failure: Error?
        private var parkedSenders: [CheckedContinuation<Void, Never>] = []
        private var parkedConsumer: CheckedContinuation<TTSAudioChunk?, Error>?
        private var producerTasks: [Task<Void, Never>] = []

        init(slotCapacity: Int, byteCapacity: Int) {
            // `Swift.max`: unqualified `max` resolves to the enclosing
            // TTSAudioChunkStream's AsyncSequence `.max()` member, not the
            // global function.
            self.slotCapacity = Swift.max(1, slotCapacity)
            self.byteCapacity = Swift.max(2, byteCapacity)
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        private var cancelledError: Error { TTSSynthesisError.cancelled }

        private func terminalError() -> Error {
            failure ?? cancelledError
        }

        // MARK: - Producer side (async, lossless, awaiting)

        private enum SendStep {
            case done
            case failed(Error)
            case park
        }

        func send(_ chunk: TTSAudioChunk) async throws {
            let payloadBytes = chunk.pcm.count
            while true {
                let step: SendStep = withLock {
                    if closed { return .failed(terminalError()) }
                    if queue.count < slotCapacity, byteCount + payloadBytes <= byteCapacity {
                        if let consumer = parkedConsumer {
                            parkedConsumer = nil
                            // Direct handoff while the consumer is parked: the
                            // chunk is delivered exactly once, queue untouched.
                            consumer.resume(returning: chunk)
                            return .done
                        }
                        queue.append(chunk)
                        byteCount += payloadBytes
                        return .done
                    }
                    return .park
                }
                switch step {
                case .done:
                    return
                case .failed(let error):
                    throw error
                case .park:
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        // Register-or-revalidate atomically: no window in which
                        // space opened but the sender stayed parked.
                        let shouldWakeNow: Bool = withLock {
                            if closed { return true }
                            if queue.count < slotCapacity, byteCount + payloadBytes <= byteCapacity {
                                return true
                            }
                            parkedSenders.append(cont)
                            return false
                        }
                        if shouldWakeNow { cont.resume() }
                    }
                    // Loop: either space opened (we enqueue now) or the channel
                    // closed (the next pass throws).
                }
            }
        }

        // MARK: - Consumer side (demand-driven)

        private enum NextStep {
            case deliver(TTSAudioChunk, wokenSender: CheckedContinuation<Void, Never>?)
            case end
            case failed(Error)
            case park
        }

        func next() async throws -> TTSAudioChunk? {
            try await withTaskCancellationHandler {
                while true {
                    let step: NextStep = withLock {
                        if !queue.isEmpty {
                            let chunk = queue.removeFirst()
                            byteCount -= chunk.pcm.count
                            let woken = parkedSenders.isEmpty ? nil : parkedSenders.removeFirst()
                            return .deliver(chunk, wokenSender: woken)
                        }
                        if closed {
                            if let failure { return .failed(failure) }
                            return .end
                        }
                        return .park
                    }
                    switch step {
                    case .deliver(let chunk, let wokenSender):
                        wokenSender?.resume()
                        return chunk
                    case .end:
                        return nil
                    case .failed(let error):
                        throw error
                    case .park:
                        return try await withCheckedThrowingContinuation {
                            (cont: CheckedContinuation<TTSAudioChunk?, Error>) in
                            // Register-or-revalidate atomically: no window in
                            // which a producer enqueued but the consumer stayed
                            // parked. The producer handoff path above never
                            // enqueues while a consumer is registered, so once
                            // parked, exactly one side owns the pending value.
                            enum Act { case deliver(TTSAudioChunk), end, fail(Error), parked }
                            let act: Act = withLock {
                                if !queue.isEmpty {
                                    let chunk = queue.removeFirst()
                                    byteCount -= chunk.pcm.count
                                    let woken = parkedSenders.isEmpty ? nil : parkedSenders.removeFirst()
                                    woken?.resume()
                                    return .deliver(chunk)
                                }
                                if closed {
                                    if let failure { return .fail(failure) }
                                    return .end
                                }
                                parkedConsumer = cont
                                return .parked
                            }
                            switch act {
                            case .deliver(let chunk): cont.resume(returning: chunk)
                            case .end: cont.resume(returning: nil)
                            case .fail(let error): cont.resume(throwing: error)
                            case .parked: break
                            }
                        }
                    }
                }
            } onCancel: {
                // Consumer task cancelled: close the channel (wakes parked
                // senders, cancels attached producers, drops the queue for
                // any future iterator — late chunks can never restart it).
                finish(failure: cancelledError)
            }
        }

        // MARK: - Producer side (synchronous, byte-capped — Apple writer)

        private enum BoundedSendResult {
            case accepted
            case rejected(consumerToFail: CheckedContinuation<TTSAudioChunk?, Error>?)
        }

        func sendBounded(_ chunk: TTSAudioChunk) -> Bool {
            let result: BoundedSendResult = withLock {
                if closed { return .rejected(consumerToFail: nil) }
                if byteCount + chunk.pcm.count > byteCapacity {
                    closed = true
                    failure = TTSSynthesisError.streamTruncated(provider: .apple)
                    let consumer = parkedConsumer
                    parkedConsumer = nil
                    return .rejected(consumerToFail: consumer)
                }
                if let consumer = parkedConsumer {
                    parkedConsumer = nil
                    consumer.resume(returning: chunk)
                    return .accepted
                }
                queue.append(chunk)
                byteCount += chunk.pcm.count
                return .accepted
            }
            switch result {
            case .accepted:
                return true
            case .rejected(let consumerToFail):
                if let consumerToFail {
                    consumerToFail.resume(
                        throwing: TTSSynthesisError.streamTruncated(provider: .apple))
                }
                return false
            }
        }

        // MARK: - Close / producer registration

        private struct CloseSnapshot {
            let wasAlreadyClosed: Bool
            let senders: [CheckedContinuation<Void, Never>]
            let consumer: CheckedContinuation<TTSAudioChunk?, Error>?
            let producers: [Task<Void, Never>]
            let failure: Error?
        }

        func finish(failure error: Error?) {
            let snapshot: CloseSnapshot = withLock {
                let wasAlreadyClosed = closed
                closed = true
                if failure == nil { failure = error }
                let senders = parkedSenders
                parkedSenders = []
                let consumer = parkedConsumer
                parkedConsumer = nil
                let producers = producerTasks
                producerTasks = []
                return CloseSnapshot(wasAlreadyClosed: wasAlreadyClosed, senders: senders,
                                     consumer: consumer, producers: producers, failure: failure)
            }
            // Cancelling attached producers happens even on double close so no
            // in-flight network read survives a terminal state.
            snapshot.producers.forEach { $0.cancel() }
            if snapshot.wasAlreadyClosed { return }
            snapshot.senders.forEach { $0.resume() }
            if let consumer = snapshot.consumer {
                if let failure = snapshot.failure { consumer.resume(throwing: failure) }
                else { consumer.resume(returning: nil) }
            }
        }

        func attach(_ task: Task<Void, Never>) {
            let cancelNow: Bool = withLock {
                if closed { return true }
                producerTasks.append(task)
                return false
            }
            if cancelNow { task.cancel() }
        }
    }

    private let storage: Storage

    private init(storage: Storage) { self.storage = storage }

    /// Create a lossless bounded channel. `slotCapacity` audio chunks may be
    /// in flight before the producer awaits; `byteCapacity` additionally caps
    /// queued PCM bytes.
    public static func make(
        slotCapacity: Int = TTSSpeechLimits.channelSlotCapacity,
        byteCapacity: Int = TTSSpeechLimits.maxSegmentAudioBytes
    ) -> (TTSAudioChunkStream, TTSAudioChunkSender) {
        let storage = Storage(slotCapacity: slotCapacity, byteCapacity: byteCapacity)
        return (TTSAudioChunkStream(storage: storage), TTSAudioChunkSender(storage: storage))
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate let storage: Storage
        public mutating func next() async throws -> TTSAudioChunk? {
            try await storage.next()
        }
    }

    public func makeAsyncIterator() -> Iterator { Iterator(storage: storage) }

    /// Producer-side handle.
    public final class Sender: Sendable {
        fileprivate let storage: Storage
        fileprivate init(storage: Storage) { self.storage = storage }

        /// Lossless: awaits while the consumer is behind. Throws `.cancelled`
        /// (or the prior failure) once the stream is closed.
        public func send(_ chunk: TTSAudioChunk) async throws {
            try await storage.send(chunk)
        }

        /// Synchronous lossless-with-byte-cap variant (Apple offline writer).
        public func sendBounded(_ chunk: TTSAudioChunk) -> Bool {
            storage.sendBounded(chunk)
        }

        /// Normal completion (EOF to the consumer) or terminal failure.
        public func finish(throwing error: Error? = nil) {
            storage.finish(failure: error)
        }

        /// Registers the producer task so consumer-side close CANCELS the
        /// network read/producer, not just the queue (no queued chunk can be
        /// re-sent after close, and no socket stays open orphaned).
        public func attach(_ task: Task<Void, Never>) {
            storage.attach(task)
        }
    }
}

public typealias TTSAudioChunkSender = TTSAudioChunkStream.Sender

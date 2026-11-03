import Foundation

import Dispatch

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// BSD-socket `NetworkConnection` for Android and other non-Apple platforms.
///
/// The upstream slice marked this type "very hacky and NOT fully fleshed
/// out"; Floe's Android port closes the concrete gaps that break real RFB:
///   * reads accumulate until `minimumLength` bytes exist (TCP may split a
///     single RFB field across packets) and retain excess bytes for the next
///     read instead of dropping them;
///   * writes loop until every byte is accepted (partial `send()` is legal);
///   * `cancel()` interrupts a blocked `recv()` and closes exactly once;
///   * connect has a bounded timeout (non-blocking connect + poll), so a
///     black-holed LAN endpoint surfaces `timedOut` instead of hanging.
final class SocketNetworkConnection: NetworkConnection {
    let settings: NetworkConnectionSettings

    private let stateLock = NSLock()
    private var socket: Socket?
    private var _status: NetworkConnectionStatus = .unknown("None")
    private var _statusUpdateHandler: NetworkConnectionStatusUpdateHandler?
    private var cancelled = false

    private var queue = DispatchQueue(label: "PLACEHOLDER")
    /// Only touched on `queue`. Keeps bytes that arrived beyond the current
    /// RFB field so the next read sees an exact byte stream.
    private var receiveBuffer = Data()
    private let receiveChunkSize = 16 * 1024

    init(settings: NetworkConnectionSettings) {
        self.settings = settings
    }

    var status: NetworkConnectionStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _status
    }

    var statusUpdateHandler: NetworkConnectionStatusUpdateHandler? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _statusUpdateHandler
        }
        set {
            stateLock.lock()
            _statusUpdateHandler = newValue
            stateLock.unlock()
        }
    }

    func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
        self.statusUpdateHandler = statusUpdateHandler
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private func setStatus(_ newStatus: NetworkConnectionStatus) {
        stateLock.lock()
        _status = newStatus
        let handler = _statusUpdateHandler
        stateLock.unlock()
        handler?(newStatus)
    }

    private func takeSocketIfCancelled() -> Socket? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled ? socket : nil
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let current = socket
        stateLock.unlock()
        // shutdown() is the only call that reliably interrupts a blocked
        // recv(). Closing from the queue alone would wait behind that recv().
        current?.shutdown()
        // Close the descriptor before VNCConnection reports .disconnected:
        // the user-visible close must follow the real socket closure, not
        // merely a queued future close behind a blocked recv(). closeSocket
        // is one-shot and shutdown() already interrupted the reader.
        current?.closeSocket()
        stateLock.lock()
        socket = nil
        stateLock.unlock()
        queue.async { [weak self] in
            self?.setStatus(.cancelled)
        }
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        setStatus(.preparing)

        queue.async { [weak self] in
            guard let self else { return }
            if self.isCancelledOnQueue { return }

            do {
                let addressInfo = try AddressInfo(host: self.settings.host,
                                                  port: self.settings.port)
                let socket = try Socket(addressInfo: addressInfo)
                self.stateLock.lock()
                self.socket = socket
                self.stateLock.unlock()

                if self.isCancelledOnQueue {
                    socket.closeSocket()
                    return
                }
                try socket.connect()
                if self.isCancelledOnQueue {
                    socket.closeSocket()
                    return
                }
                self.setStatus(.ready)
            } catch {
                if self.isCancelledOnQueue {
                    self.setStatus(.cancelled)
                } else {
                    self.setStatus(.failed(error))
                }
            }
        }
    }

    private var isCancelledOnQueue: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func currentSocket() throws -> Socket {
        stateLock.lock()
        let current = socket
        let isCancelled = cancelled
        stateLock.unlock()
        if isCancelled { throw VNCError.connection(.cancelled) }
        guard let current else {
            throw Socket.Errors.socketCreationFailed(underlyingErrorCode: nil)
        }
        return current
    }
}

// MARK: - Reading
extension SocketNetworkConnection: NetworkConnectionReading {
    func read(minimumLength: Int,
              maximumLength: Int) async throws -> Data {
        guard minimumLength > 0, maximumLength >= minimumLength else {
            throw VNCError.protocol(.invalidData)
        }
        let queue = self.queue
        let socket = try currentSocket()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    // Drain retained bytes first, then read more until the
                    // caller's minimum is satisfied. Never return more than
                    // maximumLength; keep the remainder for the next call.
                    while self.receiveBuffer.count < minimumLength {
                        var chunk = [UInt8](repeating: 0, count: self.receiveChunkSize)
                        let bytesRead = socket.receive(buffer: &chunk)
                        if bytesRead == 0 {
                            throw VNCError.connection(.closed)
                        }
                        if bytesRead < 0 {
                            throw VNCError.connection(.failed(Errors.receiveFailed))
                        }
                        self.receiveBuffer.append(contentsOf: chunk.prefix(bytesRead))
                    }
                    let take = min(self.receiveBuffer.count, maximumLength)
                    let payload = self.receiveBuffer.prefix(take)
                    self.receiveBuffer.removeFirst(take)
                    continuation.resume(returning: Data(payload))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Writing
extension SocketNetworkConnection: NetworkConnectionWriting {
    func write(data: Data) async throws {
        let queue = self.queue
        let socket = try currentSocket()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let bytesToSend = [UInt8](data)
                var offset = 0
                while offset < bytesToSend.count {
                    let slice = Array(bytesToSend[offset...])
                    let bytesSent = socket.send(buffer: slice)
                    if bytesSent < 0 {
#if canImport(Glibc)
                        if errno == EINTR { continue }
#elseif canImport(Android)
                        if errno == POSIXErrorCode.EINTR.rawValue { continue }
#elseif canImport(Darwin)
                        if errno == EINTR { continue }
#endif
                        continuation.resume(throwing: Errors.sendFailed)
                        return
                    }
                    if bytesSent == 0 {
                        continuation.resume(throwing: Errors.sendFailed)
                        return
                    }
                    offset += bytesSent
                }
                continuation.resume()
            }
        }
    }
}

// MARK: - Errors
private extension SocketNetworkConnection {
    enum Errors: LocalizedError {
        case sendFailed
        case receiveFailed

        var errorDescription: String? {
            switch self {
                case .sendFailed:
                    "Send failed"
                case .receiveFailed:
                    "Receive failed"
            }
        }
    }
}

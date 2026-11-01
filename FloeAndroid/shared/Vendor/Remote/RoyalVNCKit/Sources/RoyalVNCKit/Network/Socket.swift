#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#endif

final class Socket: Sendable {
    let addressInfo: AddressInfo

#if canImport(Glibc) || canImport(Darwin) || canImport(Android)
    private typealias NativeSocket = Int32
#elseif canImport(WinSDK)
    private typealias NativeSocket = SOCKET
#endif

    private let nativeSocket: NativeSocket
    /// Android/Linux lifecycle hardening (Floe port): cancel() must be able
    /// to interrupt a blocking recv() from another thread, and a socket is
    /// closed exactly once.
    private let closeLock = NSLock()
    private var closed = false

    init(addressInfo: AddressInfo) throws(Errors) {
        let nativeSocket = socket(
            addressInfo.family,
            addressInfo.socktype,
            addressInfo.protocol
        )

#if canImport(Glibc) || canImport(Darwin) || canImport(Android)
        guard nativeSocket >= 0 else {
            throw .socketCreationFailed(underlyingErrorCode: nil)
        }
#elseif canImport(WinSDK)
        guard nativeSocket != INVALID_SOCKET else {
            let lastError = WSAGetLastError()

            throw .socketCreationFailed(underlyingErrorCode: lastError)
        }
#endif

        self.addressInfo = addressInfo
        self.nativeSocket = nativeSocket
    }

    func connect() throws(Errors) {
        // Floe Android port: bounded, interruptible connect. A blocking
        // BSD connect() can hang for the OS default (~75 s) and is not a
        // usable VNC failure path. Non-blocking connect + poll keeps the
        // configured 15 s ceiling and lets cancel() unblock the wait.
#if canImport(Glibc) || canImport(Android) || canImport(Darwin)
        try connectNonBlocking(timeoutSeconds: 15)
#else
        let connectResult: Int32
        connectResult = WinSDK.connect(
            nativeSocket,
            addressInfo.addr,
            .init(addressInfo.addrlen)
        )
        guard connectResult >= 0 else {
            throw .connectFailed(underlyingErrorCode: connectResult)
        }
#endif
    }

#if canImport(Glibc) || canImport(Android) || canImport(Darwin)
    private func connectNonBlocking(timeoutSeconds: Int) throws(Errors) {
        func setNonBlocking(_ enabled: Bool) {
#if canImport(Glibc)
            _ = Glibc.fcntl(nativeSocket, F_SETFL, enabled ? O_NONBLOCK : 0)
#elseif canImport(Android)
            _ = Android.fcntl(nativeSocket, F_SETFL, enabled ? O_NONBLOCK : 0)
#elseif canImport(Darwin)
            _ = Darwin.fcntl(nativeSocket, F_SETFL, enabled ? O_NONBLOCK : 0)
#endif
        }

        setNonBlocking(true)
        defer { setNonBlocking(false) }

        let connectResult: Int32
#if canImport(Glibc)
        connectResult = Glibc.connect(nativeSocket, addressInfo.addr, addressInfo.addrlen)
        let inProgress = errno == EINPROGRESS || errno == EINTR
#elseif canImport(Android)
        connectResult = Android.connect(nativeSocket, addressInfo.addr!, addressInfo.addrlen)
        let inProgress = errno == POSIXErrorCode.EINPROGRESS.rawValue ||
            errno == POSIXErrorCode.EINTR.rawValue
#elseif canImport(Darwin)
        connectResult = Darwin.connect(nativeSocket, addressInfo.addr, addressInfo.addrlen)
        let inProgress = errno == EINPROGRESS || errno == EINTR
#endif

        if connectResult == 0 { return }
        guard inProgress else {
            throw .connectFailed(underlyingErrorCode: connectResult)
        }

        var descriptor = pollfd(fd: nativeSocket, events: Int16(POLLOUT), revents: 0)
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let remainingMs = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            if remainingMs == 0 { throw .connectTimedOut }
            let pollResult = poll(&descriptor, 1, Int32(remainingMs))
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw .connectFailed(underlyingErrorCode: pollResult)
            }
            if pollResult == 0 { throw .connectTimedOut }
            break
        }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = getsockopt(
            nativeSocket,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        )
        guard optionResult == 0 else {
            throw .connectFailed(underlyingErrorCode: optionResult)
        }
        guard socketError == 0 else {
            throw .connectFailed(underlyingErrorCode: socketError)
        }
    }
#endif

    func receive(buffer: inout [UInt8]) -> Int {
        let bufferSize = buffer.count

        let bytesRead: Int = buffer.withUnsafeMutableBytes { bufferPtr in
            guard let bufferPtrAddr = bufferPtr.baseAddress else {
                return 0
            }

            let ret = recv(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferSize),
                0
            )

            return .init(ret)
        }

        return bytesRead
    }

    func send(buffer: [UInt8]) -> Int {
        let bufferCount = buffer.count

        let bytesSent: Int = buffer.withUnsafeBytes { bufferPtr in
            guard let bufferPtrAddr = bufferPtr.baseAddress else {
                return -1
            }

#if canImport(Glibc)
            let ret = Glibc.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                0
            )
#elseif canImport(Android)
            let ret = Android.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                0
            )
#elseif canImport(Darwin)
            let ret = Darwin.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                0
            )
#elseif canImport(WinSDK)
            let ret = WinSDK.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                0
            )
#endif

            return .init(ret)
        }

        return bytesSent
    }

    /// Unblocks a pending recv() without closing the descriptor. Safe to call
    /// repeatedly and from any thread. The receive path observes 0 and stops.
    func shutdown() {
        closeLock.lock()
        let alreadyClosed = closed
        closeLock.unlock()
        guard !alreadyClosed else { return }
#if canImport(Glibc)
        _ = Glibc.shutdown(nativeSocket, Int32(SHUT_RDWR))
#elseif canImport(Android)
        _ = Android.shutdown(nativeSocket, Int32(SHUT_RDWR))
#elseif canImport(Darwin)
        _ = Darwin.shutdown(nativeSocket, Int32(SHUT_RDWR))
#elseif canImport(WinSDK)
        _ = WinSDK.shutdown(nativeSocket, SD_SEND)
#endif
    }

    /// Closes the descriptor exactly once.
    func closeSocket() {
        closeLock.lock()
        if closed {
            closeLock.unlock()
            return
        }
        closed = true
        closeLock.unlock()
#if canImport(Glibc)
        _ = Glibc.close(nativeSocket)
#elseif canImport(Android)
        _ = Android.close(nativeSocket)
#elseif canImport(Darwin)
        _ = Darwin.close(nativeSocket)
#elseif canImport(WinSDK)
        _ = WinSDK.closesocket(nativeSocket)
#endif
    }

    deinit {
        closeSocket()
    }
}

// MARK: - Errors
extension Socket {
    enum Errors: LocalizedError {
        case socketCreationFailed(underlyingErrorCode: Int32?)
        case connectFailed(underlyingErrorCode: Int32)
        case connectTimedOut

        var errorDescription: String? {
            switch self {
                case .socketCreationFailed(let underlyingErrorCode):
                    let underlyingErrorCodeStr: String

                    if let underlyingErrorCode {
                        underlyingErrorCodeStr = "\(underlyingErrorCode)"
                    } else {
                        underlyingErrorCodeStr = "N/A"
                    }

                    return "Socket creation failed (\(underlyingErrorCodeStr))"
                case .connectFailed(let underlyingErrorCode):
                    return "Connect failed (\(underlyingErrorCode))"
                case .connectTimedOut:
                    return "Connect timed out"
            }
        }
    }
}

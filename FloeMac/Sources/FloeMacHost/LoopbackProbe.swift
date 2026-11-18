// Floe Mac M00 — bounded loopback checks used by the embedded Bridge probe.
//
// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum LoopbackProbe {
    /// True when a TCP connection to 127.0.0.1:<port> succeeds within the
    /// timeout. A failed connection is the only case treated as "free"; the
    /// caller still fails closed if the embedded service cannot bind.
    static func isListening(port: UInt16, timeout: TimeInterval = 0.25) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var writeSet = fd_set()
        fdZero(&writeSet)
        fdSet(descriptor, &writeSet)
        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        let selected = select(descriptor + 1, nil, &writeSet, nil, &timeoutValue)
        guard selected > 0, fdIsSet(descriptor, &writeSet) else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    /// Sends one bounded raw request and returns the first response line.
    /// The existing BridgeHTTPServer rejects anything but POST /rpc with 400,
    /// so receiving "HTTP/1.1 400 Bad Request" proves its listener is serving.
    static func httpStatusLine(
        port: UInt16,
        request: String,
        timeout: TimeInterval = 2
    ) -> String? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = receiveTimeout
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let bytes = Array(request.utf8)
        let sent = bytes.withUnsafeBytes { buffer in
            send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == bytes.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        let text = String(decoding: buffer.prefix(received), as: UTF8.self)
        return text.components(separatedBy: "\r\n").first
    }

    private static func fdZero(_ set: inout fd_set) {
        withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }

    private static func fdSet(_ descriptor: Int32, _ set: inout fd_set) {
        let offset = Int(descriptor) / 32
        let mask = Int32(1) << (Int(descriptor) % 32)
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { words in
                words[offset] |= mask
            }
        }
    }

    private static func fdIsSet(_ descriptor: Int32, _ set: inout fd_set) -> Bool {
        let offset = Int(descriptor) / 32
        let mask = Int32(1) << (Int(descriptor) % 32)
        return withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { words in
                (words[offset] & mask) != 0
            }
        }
    }
}

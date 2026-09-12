import Foundation
import FloeCore
import Darwin

/// Single getaddrinfo walk for device network diagnostics (ping, traceroute
/// and DNS share it instead of each re-walking addrinfo).
enum HostResolver {
    /// IPv4 A records as network-order `sin_addr.s_addr` values, suitable for
    /// building sockaddr_in without further conversion.
    static func ipv4Addresses(_ host: String) throws -> [UInt32] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw FloeError.validationFailed("Device DNS lookup failed")
        }
        defer { freeaddrinfo(first) }
        var addresses: [UInt32] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            if current.pointee.ai_family == AF_INET,
               current.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size) {
                let address = current.pointee.ai_addr
                    .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                addresses.append(address.sin_addr.s_addr)
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    static func presentation(_ address: UInt32) -> String {
        var value = in_addr(s_addr: address)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

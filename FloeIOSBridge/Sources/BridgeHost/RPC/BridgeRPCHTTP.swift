import Darwin
import Foundation

import BridgeCore

/// Bounded, single-request HTTP/1.1 framing for the Bridge listener.
///
/// The parser accepts exactly one request, enforces the configured head/body
/// budgets before allocation, rejects transfer encodings and duplicate framing
/// headers, and refuses trailing bytes so one connection cannot smuggle a
/// second request. HTTP keep-alive is intentionally not supported.
public enum BridgeRPCHTTPParser {
    public enum Result: Sendable, Equatable {
        case incomplete
        case invalid(status: Int, code: String, message: String)
        case complete(BridgeRPCParsedRequest)
    }

    private static let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    public static func inspect(_ data: Data, limits: BridgeRPCLimits) -> Result {
        guard let separator = data.range(of: terminator) else {
            if data.count > limits.maxRequestHeadBytes {
                return .invalid(status: 431, code: "request_head_too_large",
                                message: "The HTTP request head exceeds the bounded size.")
            }
            return .incomplete
        }
        let headerLength = separator.lowerBound - data.startIndex
        guard headerLength <= limits.maxRequestHeadBytes else {
            return .invalid(status: 431, code: "request_head_too_large",
                            message: "The HTTP request head exceeds the bounded size.")
        }
        let headerData = data.subdata(in: data.startIndex..<separator.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8),
              !headerText.contains("\u{0}") else {
            return .invalid(status: 400, code: "bad_request_head",
                            message: "The HTTP request head is not valid UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .invalid(status: 400, code: "missing_request_line",
                            message: "The HTTP request line is missing.")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            return .invalid(status: 400, code: "bad_request_line",
                            message: "The HTTP request line is malformed.")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard method.utf8.count <= 16,
              method.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else {
            return .invalid(status: 400, code: "bad_method", message: "The HTTP method is malformed.")
        }
        guard target.utf8.count <= 2_048,
              target.hasPrefix("/"),
              !target.contains("#"),
              !target.utf8.contains(where: { $0 < 0x21 || $0 == 0x7F }) else {
            return .invalid(status: 400, code: "bad_path", message: "The request target is malformed.")
        }
        guard version == "HTTP/1.1" else {
            return .invalid(status: 400, code: "bad_version", message: "HTTP/1.1 is required.")
        }

        var headers: [String: String] = [:]
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard !line.isEmpty else {
                return .invalid(status: 400, code: "unexpected_empty_header",
                                message: "The header block contains an unexpected empty line.")
            }
            guard line.first != " ", line.first != "\t" else {
                return .invalid(status: 400, code: "folded_header",
                                message: "Folded HTTP headers are not accepted.")
            }
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, code: "bad_header", message: "A header is malformed.")
            }
            let rawName = line[..<colon]
            let rawValue = line[line.index(after: colon)...]
            let name = rawName.lowercased()
            guard isHeaderName(name), name.utf8.count <= 64 else {
                return .invalid(status: 400, code: "bad_header_name",
                                message: "A header name is malformed.")
            }
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard value.utf8.count <= 1_024,
                  !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
                return .invalid(status: 400, code: "bad_header_value",
                                message: "A header value is malformed.")
            }
            switch name {
            case "content-length":
                guard contentLength == nil else {
                    return .invalid(status: 400, code: "duplicate_content_length",
                                    message: "Duplicate Content-Length is not accepted.")
                }
                guard isDecimal(value), value.utf8.count <= 8,
                      !(value.count > 1 && value.hasPrefix("0")),
                      let parsed = Int(value) else {
                    return .invalid(status: 400, code: "bad_content_length",
                                    message: "Content-Length is malformed.")
                }
                guard parsed <= limits.maxRequestBodyBytes else {
                    return .invalid(status: 413, code: "request_body_too_large",
                                    message: "The request body exceeds the bounded size.")
                }
                contentLength = parsed
            case "transfer-encoding", "expect", "content-encoding", "upgrade":
                return .invalid(status: 400, code: "unsupported_transfer",
                                message: "Transfer/expect/upgrade headers are not supported.")
            default:
                guard headers[name] == nil else {
                    return .invalid(status: 400, code: "duplicate_header",
                                    message: "Duplicate HTTP headers are not accepted.")
                }
                headers[name] = value
            }
        }
        guard let host = headers["host"], !host.isEmpty, host.utf8.count <= 255 else {
            return .invalid(status: 400, code: "missing_host", message: "The Host header is required.")
        }
        let bodyLength = contentLength ?? 0
        if method != "POST", bodyLength != 0 {
            return .invalid(status: 400, code: "unexpected_body",
                            message: "This method does not accept a body.")
        }
        guard bodyLength <= limits.maxRequestBodyBytes else {
            return .invalid(status: 413, code: "request_body_too_large",
                            message: "The request body exceeds the bounded size.")
        }
        let total = headerLength + terminator.count + bodyLength
        if data.count < total { return .incomplete }
        guard data.count == total else {
            return .invalid(status: 400, code: "unexpected_trailing_bytes",
                            message: "Trailing bytes after the HTTP request are not accepted.")
        }
        let body = data.subdata(in: (data.startIndex + headerLength + terminator.count)..<data.endIndex)
        let queryIndex = target.firstIndex(of: "?")
        let pathOnly = queryIndex.map { String(target[..<$0]) } ?? target
        let query = queryIndex.map { String(target[target.index(after: $0)...]) } ?? ""
        return .complete(BridgeRPCParsedRequest(
            method: method,
            target: target,
            pathOnly: pathOnly,
            query: query,
            headers: headers,
            body: body
        ))
    }

    private static func isHeaderName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return false }
        for byte in bytes {
            switch byte {
            case 0x61...0x7A, 0x30...0x39, 0x21, 0x23, 0x24, 0x25, 0x26,
                 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func isDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}

public struct BridgeRPCParsedRequest: Sendable, Equatable {
    public var method: String
    public var target: String
    public var pathOnly: String
    public var query: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String,
                target: String,
                pathOnly: String,
                query: String,
                headers: [String: String],
                body: Data) {
        self.method = method
        self.target = target
        self.pathOnly = pathOnly
        self.query = query
        self.headers = headers
        self.body = body
    }

    public var serviceRequest: BridgeRPCHTTPRequest {
        BridgeRPCHTTPRequest(method: method,
                             path: target,
                             pathOnly: pathOnly,
                             query: query,
                             headers: headers,
                             body: body)
    }
}

// MARK: - Peer identity from the accepted kernel socket

public enum BridgeRPCNetworkPeer {
    /// Classifies the accepted peer from its sockaddr and the local interface
    /// table. Request headers never contribute to this decision.
    public static func classify(_ storage: sockaddr_storage) -> BridgeRPCPeerInfo {
        var mutable = storage
        switch Int32(mutable.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &mutable) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var octets = address.pointee.sin_addr
                    let text = withUnsafePointer(to: &octets) { raw in
                        inet_ntop(AF_INET, raw, &host, socklen_t(INET_ADDRSTRLEN))
                    }
                    let ip = text == nil ? "unknown" : stringFromCChars(host)
                    let loopback = ip.hasPrefix("127.")
                    if loopback {
                        return BridgeRPCPeerInfo(address: ip, via: .local, isLoopback: true)
                    }
                    let via = interfaceVia(containingIPv4: address.pointee.sin_addr)
                    return BridgeRPCPeerInfo(address: ip, via: via, isLoopback: false)
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &mutable) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                    var host = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var octets = address.pointee.sin6_addr
                    let text = withUnsafePointer(to: &octets) { raw in
                        inet_ntop(AF_INET6, raw, &host, socklen_t(INET6_ADDRSTRLEN))
                    }
                    var ip = text == nil ? "unknown" : stringFromCChars(host)
                    if let percent = ip.firstIndex(of: "%") { ip = String(ip[..<percent]) }
                    var bytes = [UInt8](repeating: 0, count: 16)
                    withUnsafeBytes(of: &octets) { raw in
                        if let base = raw.baseAddress {
                            bytes.withUnsafeMutableBytes { destination in
                                destination.copyMemory(from: UnsafeRawBufferPointer(
                                    start: base, count: 16
                                ))
                            }
                        }
                    }
                    let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
                    let mapped = bytes[0..<10].allSatisfy { $0 == 0 }
                        && bytes[10] == 0xFF && bytes[11] == 0xFF
                    let mappedLoopback = mapped && bytes[12] == 127
                    if loopback || mappedLoopback {
                        return BridgeRPCPeerInfo(address: ip, via: .local, isLoopback: true)
                    }
                    let via: BridgeRPCPeerVia
                    if address.pointee.sin6_scope_id != 0 {
                        via = interfaceVia(scopeID: address.pointee.sin6_scope_id)
                    } else {
                        via = interfaceVia(containingIPv6: octets)
                    }
                    return BridgeRPCPeerInfo(address: ip, via: via, isLoopback: false)
                }
            }
        default:
            return .unknown
        }
    }

    static func interfaceVia(containingIPv4 address: in_addr) -> BridgeRPCPeerVia {
        let peer = UInt32(bigEndian: address.s_addr)
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else {
            return .other
        }
        defer { freeifaddrs(interfacePointer) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let mine = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask: UInt32?
            if let netmask = entry.ifa_netmask {
                mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
            } else {
                mask = nil
            }
            if let mask, mask != 0, (mine & mask) == (peer & mask) {
                return via(for: stringFromCString(entry.ifa_name))
            }
        }
        return .other
    }

    static func interfaceVia(containingIPv6 address: in6_addr) -> BridgeRPCPeerVia {
        var peerBytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: address) { raw in
            if let base = raw.baseAddress {
                peerBytes.withUnsafeMutableBytes { destination in
                    destination.copyMemory(from: UnsafeRawBufferPointer(start: base, count: 16))
                }
            }
        }
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else {
            return .other
        }
        defer { freeifaddrs(interfacePointer) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET6),
                  let netmask = entry.ifa_netmask else { continue }
            let mine = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr
            }
            var mineBytes = [UInt8](repeating: 0, count: 16)
            var maskBytes = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: mine) { raw in
                if let base = raw.baseAddress {
                    mineBytes.withUnsafeMutableBytes {
                        $0.copyMemory(from: UnsafeRawBufferPointer(start: base, count: 16))
                    }
                }
            }
            withUnsafeBytes(of: mask) { raw in
                if let base = raw.baseAddress {
                    maskBytes.withUnsafeMutableBytes {
                        $0.copyMemory(from: UnsafeRawBufferPointer(start: base, count: 16))
                    }
                }
            }
            var matches = true
            var hasPrefix = false
            for index in 0..<16 where maskBytes[index] != 0 {
                hasPrefix = true
                if (mineBytes[index] & maskBytes[index]) != (peerBytes[index] & maskBytes[index]) {
                    matches = false
                    break
                }
            }
            if hasPrefix && matches {
                return via(for: stringFromCString(entry.ifa_name))
            }
        }
        return .other
    }

    static func interfaceVia(scopeID: UInt32) -> BridgeRPCPeerVia {
        guard scopeID != 0 else { return .other }
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
        guard if_indextoname(scopeID, &name) != nil else { return .other }
        return via(for: stringFromCChars(name))
    }

    public static func via(for interfaceName: String) -> BridgeRPCPeerVia {
        if interfaceName.hasPrefix("awdl") || interfaceName.hasPrefix("llw") {
            return .nearby
        }
        if interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ipsec")
            || interfaceName.hasPrefix("ppp") {
            return .vpn
        }
        if interfaceName.hasPrefix("pdp_ip") { return .cellular }
        if interfaceName.hasPrefix("lo") { return .local }
        if interfaceName.hasPrefix("en") || interfaceName.hasPrefix("bridge")
            || interfaceName.hasPrefix("ap") {
            return .lan
        }
        return .other
    }
}

private func stringFromCChars(_ bytes: [CChar]) -> String {
    String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func stringFromCString(_ pointer: UnsafePointer<CChar>) -> String {
    let count = strlen(pointer)
    let raw = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
}

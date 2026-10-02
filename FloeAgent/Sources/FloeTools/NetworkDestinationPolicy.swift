// FloeTools — Destination classification for outbound tool network requests.
//
// SSRF boundary shared by every tool that initiates HTTP traffic: numeric
// addresses are classified into globally public, transient tunnel and
// non-public ranges. The transient tunnel class is RFC 2544's 198.18.0.0/15
// benchmark block, which transparent VPN/proxy tunnels on iOS (the
// Clash/Surge fake-IP family) commonly hand back for every public DNS name;
// the tunnel process then owns the real connection, routed by TLS SNI.
//
// Safety note: 198.18.0.0/15 is a reserved range, not an intrinsically safe
// one. The addresses are potentially routable inside someone's network and
// are never accepted by default; callers may admit them only for a specific
// fixed HTTPS provider endpoint bound to a specific provider kind, never as
// a general relaxation or by host name alone.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import FloeCore

public enum NetworkAddressClass: Sendable, Equatable {
    case publicAddress
    /// 198.18.0.0/15: reserved benchmark range, used on-device as the fake-IP
    /// pool of transparent VPN tunnels. Not globally routable, but potentially
    /// routable inside a local network — not safe to admit by default.
    case transientTunnel
    case nonPublic
}

public enum NetworkDestinationError: Error, Sendable, Equatable {
    case privateTarget(String)
    case resolutionFailed(String)
}

public enum NetworkDestinationPolicy: Sendable {
    /// Validate one host name against its resolved addresses. Every resolved
    /// address must be globally public; `transientTunnel` addresses are
    /// accepted only when `allowTransientTunnel` is true, which callers grant
    /// exclusively to fixed built-in provider endpoints. DNS failure and an
    /// empty resolution set are fail-closed.
    public static func validate(
        host: String,
        allowTransientTunnel: Bool,
        resolve: @Sendable (String) throws -> [String]
    ) throws {
        let addresses: [String]
        do {
            addresses = try resolve(host)
        } catch {
            throw NetworkDestinationError.resolutionFailed(host)
        }
        guard !addresses.isEmpty else {
            throw NetworkDestinationError.resolutionFailed(host)
        }
        for literal in addresses {
            switch classify(literal) {
            case .publicAddress:
                continue
            case .transientTunnel where allowTransientTunnel:
                continue
            default:
                FloeLogger(category: .tools).debug(
                    "networkDestinationRejected host=\(host) address=\(literal) transientAllowed=\(allowTransientTunnel)"
                )
                throw NetworkDestinationError.privateTarget(host)
            }
        }
    }

    /// `SOCK_STREAM` is an `Int32` constant on Darwin; Glibc imports the named
    /// C enum, so the `addrinfo` field needs its raw value there.
    private static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #elseif canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    /// Live resolver: getaddrinfo (AI_ADDRCONFIG, AF_UNSPEC, TCP/443 hints),
    /// rendered as numeric IP literals. Failure throws; callers map the error.
    public static func systemResolve(_ host: String) throws -> [String] {
        // Darwin and Glibc import `addrinfo` with different initializer
        // argument orders. Start from the zeroed C struct and assign only the
        // fields used by this resolver so both layouts compile identically.
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Self.streamSocketType
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
            throw NetworkDestinationError.resolutionFailed(host)
        }
        defer { freeaddrinfo(first) }
        var literals: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            guard let address = current.pointee.ai_addr,
                  let literal = numericHost(address, family: current.pointee.ai_family) else {
                // Validation promises to check every resolved address. An
                // unrenderable result must not disappear from that set.
                throw NetworkDestinationError.resolutionFailed(host)
            }
            literals.append(literal)
            cursor = current.pointee.ai_next
        }
        return literals
    }

    /// Classify a numeric IPv4/IPv6 literal.
    public static func classify(_ literal: String) -> NetworkAddressClass {
        if literal.contains(":") {
            guard let bytes = parseIPv6(literal) else { return .nonPublic }
            return classifyIPv6(bytes)
        }
        guard let bytes = parseIPv4(literal) else { return .nonPublic }
        return classifyIPv4(bytes)
    }

    // MARK: - IPv4

    /// Range decisions preserve the pre-existing conservative boundaries of
    /// the SSRF guard exactly; the repair only splits 198.18.0.0/15 out as
    /// `transientTunnel` instead of folding it into non-public.
    private static func classifyIPv4(_ bytes: [UInt8]) -> NetworkAddressClass {
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return .nonPublic }
        if first == 100 && (64...127).contains(second) { return .nonPublic } // CGNAT
        if first == 169 && second == 254 { return .nonPublic } // link local
        if first == 172 && (16...31).contains(second) { return .nonPublic }
        if first == 192 && (second == 0 || second == 168) { return .nonPublic }
        if first == 198 && (second == 18 || second == 19) { return .transientTunnel }
        if first == 198 && second == 51 { return .nonPublic } // conservative: was fully blocked
        if first == 203 && second == 0 { return .nonPublic } // conservative: was fully blocked
        return .publicAddress
    }

    // MARK: - IPv6

    private static func classifyIPv6(_ bytes: [UInt8]) -> NetworkAddressClass {
        guard bytes.count == 16 else { return .nonPublic }
        if bytes.allSatisfy({ $0 == 0 }) { return .nonPublic } // unspecified ::
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .nonPublic } // ::1
        if bytes[0] & 0xfe == 0xfc { return .nonPublic } // unique local fc00::/7
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .nonPublic } // link local
        if bytes[0] == 0xff { return .nonPublic } // multicast
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x0d, 0xb8] { return .nonPublic } // documentation
        if Array(bytes.prefix(12)) == Array(repeating: 0, count: 10) + [0xff, 0xff] {
            // IPv4-mapped address: apply IPv4 rules to the embedded address.
            return classifyIPv4(Array(bytes.suffix(4)))
        }
        return .publicAddress
    }

    // MARK: - Parsing

    private static func parseIPv4(_ literal: String) -> [UInt8]? {
        var address = in_addr()
        guard literal.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address.s_addr) { Array($0) }
    }

    private static func parseIPv6(_ literal: String) -> [UInt8]? {
        var address = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// Render one resolved sockaddr as a numeric literal. The socket-address
    /// length comes from the family getaddrinfo reported: Darwin's sockaddr
    /// carries `sa_len`, Glibc's does not, so reading that field is not
    /// portable. An unknown family fails closed by returning nil.
    private static func numericHost(
        _ address: UnsafePointer<sockaddr>,
        family: Int32
    ) -> String? {
        guard Int32(address.pointee.sa_family) == family else { return nil }
        let addressLength: socklen_t
        switch family {
        case AF_INET:
            addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6:
            addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default:
            return nil
        }
        let capacity = Int(NI_MAXHOST)
        var buffer = [CChar](repeating: 0, count: capacity)
        let status = getnameinfo(
            address,
            addressLength,
            &buffer,
            socklen_t(capacity),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public enum IPAddressClassification: String, Sendable {
    case publicInternet, localOrSpecialUse
    public static func classify(_ text: String) throws -> Self { try NumericIPAddress(text).classification }
}

struct NumericIPAddress: Sendable {
    let canonical: String
    let classification: IPAddressClassification
    init(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 64, !text.contains("\0") else { throw IPInformationError.invalidAddress }
        var bytes = [UInt8](repeating: 0, count: 16)
        if bytes.withUnsafeMutableBytes({ inet_pton(AF_INET, text, $0.baseAddress) }) == 1 {
            canonical = bytes.prefix(4).map(String.init).joined(separator: ".")
            classification = Self.v4(Array(bytes.prefix(4))); return
        }
        guard bytes.withUnsafeMutableBytes({ inet_pton(AF_INET6, text, $0.baseAddress) }) == 1 else { throw IPInformationError.invalidAddress }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            let v4 = Array(bytes.suffix(4)); canonical = v4.map(String.init).joined(separator: ".")
            classification = Self.v4(v4); return
        }
        let capacity = Int(INET6_ADDRSTRLEN)
        var buffer = [CChar](repeating: 0, count: capacity)
        guard bytes.withUnsafeBytes({ inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(capacity)) }) != nil else { throw IPInformationError.invalidAddress }
        canonical = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Numeric special-use ranges are handled locally. No DNS or external
        // geolocation request is made, including IPv4-mapped private IPv6.
        let special = ["::/96", "64:ff9b:1::/48", "100::/64", "100:0:0:1::/64",
                       "2001::/23", "2001:db8::/32", "2002::/16", "3fff::/20",
                       "5f00::/16", "fc00::/7", "fe80::/10", "fec0::/10", "ff00::/8"]
        let globalExceptions = ["2001:1::1/128", "2001:1::2/128", "2001:1::3/128", "2001:3::/32",
                                "2001:4:112::/48", "2001:20::/28", "2001:30::/28", "64:ff9b::/96"]
        let allowed = globalExceptions.contains { Self.contains(bytes, cidr: $0) }
        classification = allowed || ((bytes[0] & 0xe0) == 0x20 && !special.contains { Self.contains(bytes, cidr: $0) }) ? .publicInternet : .localOrSpecialUse
    }
    private static func v4(_ b: [UInt8]) -> IPAddressClassification {
        let address = b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Globally reachable exceptions inside the IETF protocol block.
        if address == 0xc0000009 || address == 0xc000000a { return .publicInternet }
        let ranges: [(UInt32, Int)] = [(0x00000000,8),(0x0a000000,8),(0x64400000,10),(0x7f000000,8),
            (0xa9fe0000,16),(0xac100000,12),(0xc0000000,24),(0xc0000200,24),(0xc0586300,24),
            (0xc0a80000,16),(0xc6120000,15),(0xc6336400,24),(0xcb007100,24),(0xe0000000,4),(0xf0000000,4)]
        return ranges.contains { network, prefix in address & (UInt32.max << (32-prefix)) == network } ? .localOrSpecialUse : .publicInternet
    }
    private static func contains(_ bytes: [UInt8], cidr: String) -> Bool {
        let pair = cidr.split(separator: "/"); guard pair.count == 2, let bits = Int(pair[1]) else { return false }
        var network = [UInt8](repeating: 0, count: 16)
        guard network.withUnsafeMutableBytes({ inet_pton(AF_INET6, String(pair[0]), $0.baseAddress) }) == 1 else { return false }
        return (0..<bits).allSatisfy { index in
            let mask: UInt8 = 1 << (7-index%8)
            return bytes[index/8] & mask == network[index/8] & mask
        }
    }
}

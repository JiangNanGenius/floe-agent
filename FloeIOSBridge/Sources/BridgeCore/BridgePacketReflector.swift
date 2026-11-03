import Foundation

public enum BridgePacketRejection: String, Error, Equatable, Sendable {
    case empty
    case notIPv4
    case truncatedHeader
    case invalidHeaderLength
    case invalidTotalLength
    case fragmented
    case unexpectedAddresses
    case invalidHeaderChecksum
    case lengthMismatch
}

public enum BridgeReflectionResult: Equatable, Sendable {
    case reflected([UInt8])
    case rejected(BridgePacketRejection)
}

/// Stateless-in-payload, stateful-only-in-counters IPv4 reflector.
///
/// A packet is accepted only when it is a non-fragmented IPv4 datagram whose
/// source and destination are exactly the tunnel interface and the single peer
/// address. Source and destination are swapped; the IPv4 header checksum is
/// recomputed (it is invariant under the swap, but recomputing keeps this
/// correct if a future option changes). TCP/UDP checksums cover a pseudo-header
/// whose source/destination sum is unchanged by the swap, so they stay valid.
public struct BridgeIPv4Reflector: Sendable {
    public struct Counters: Equatable, Sendable {
        public var received: UInt64 = 0
        public var reflected: UInt64 = 0
        public var rejected: UInt64 = 0
        public var fragments: UInt64 = 0
        public var lastRejection: BridgePacketRejection?

        public init() {}
    }

    public let interfaceAddress: UInt32
    public let peerAddress: UInt32
    public private(set) var counters = Counters()

    public init(
        interfaceAddress: UInt32 = BridgeTransport.interfaceAddressValue,
        peerAddress: UInt32 = BridgeTransport.peerAddressValue
    ) {
        self.interfaceAddress = interfaceAddress
        self.peerAddress = peerAddress
    }

    public mutating func reflect(_ packet: [UInt8]) -> BridgeReflectionResult {
        counters.received &+= 1
        switch Self.validateAndSwap(packet, interfaceAddress: interfaceAddress, peerAddress: peerAddress) {
        case .success(let reflected):
            counters.reflected &+= 1
            return .reflected(reflected)
        case .failure(let rejection):
            counters.rejected &+= 1
            counters.lastRejection = rejection
            if rejection == .fragmented { counters.fragments &+= 1 }
            return .rejected(rejection)
        }
    }

    public func snapshotJSON() -> [String: Any] {
        var value: [String: Any] = [
            "received": counters.received,
            "reflected": counters.reflected,
            "rejected": counters.rejected,
            "fragments": counters.fragments,
            "interfaceAddress": Self.addressString(interfaceAddress),
            "peerAddress": Self.addressString(peerAddress),
        ]
        if let rejection = counters.lastRejection { value["lastRejection"] = rejection.rawValue }
        return value
    }

    public static func validateAndSwap(
        _ packet: [UInt8],
        interfaceAddress: UInt32,
        peerAddress: UInt32
    ) -> Result<[UInt8], BridgePacketRejection> {
        guard !packet.isEmpty else { return .failure(.empty) }
        guard packet.count >= 20 else { return .failure(.truncatedHeader) }
        guard packet[0] >> 4 == 4 else { return .failure(.notIPv4) }

        let headerLength = Int(packet[0] & 0x0F) * 4
        guard headerLength >= 20 else { return .failure(.invalidHeaderLength) }

        let totalLength = Int(packet[2]) << 8 | Int(packet[3])
        guard totalLength >= headerLength else { return .failure(.invalidTotalLength) }
        guard totalLength == packet.count else { return .failure(.lengthMismatch) }
        guard headerLength <= totalLength else { return .failure(.invalidHeaderLength) }

        let flags = packet[6] >> 5
        let fragmentOffset = (Int(packet[6] & 0x1F) << 8) | Int(packet[7])
        guard (flags & 0x1) == 0, fragmentOffset == 0 else { return .failure(.fragmented) }

        let source = readUInt32(packet, at: 12)
        let destination = readUInt32(packet, at: 16)
        let forward = source == interfaceAddress && destination == peerAddress
        let reverse = source == peerAddress && destination == interfaceAddress
        guard forward || reverse else { return .failure(.unexpectedAddresses) }

        guard headerChecksumIsValid(packet, headerLength: headerLength) else {
            return .failure(.invalidHeaderChecksum)
        }

        var output = packet
        writeUInt32(destination, into: &output, at: 12)
        writeUInt32(source, into: &output, at: 16)
        output[10] = 0
        output[11] = 0
        let checksum = internetChecksum(output, range: 0..<headerLength)
        output[10] = UInt8((checksum >> 8) & 0xFF)
        output[11] = UInt8(checksum & 0xFF)
        return .success(output)
    }

    public static func headerChecksumIsValid(_ packet: [UInt8], headerLength: Int) -> Bool {
        guard headerLength >= 20, packet.count >= headerLength else { return false }
        return internetChecksum(packet, range: 0..<headerLength) == 0
    }

    public static func internetChecksum(_ bytes: [UInt8], range: Range<Int>) -> UInt16 {
        var sum: UInt32 = 0
        var index = range.lowerBound
        while index + 1 < range.upperBound {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < range.upperBound {
            sum &+= UInt32(bytes[index]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    public static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }

    public static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    public static func addressString(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Builds a deterministic IPv4 TCP packet for checks and diagnostics. The
    /// checksum fields are the only computed parts; the caller supplies the
    /// header flags and payload.
    public static func makePacket(
        source: UInt32,
        destination: UInt32,
        protocolNumber: UInt8 = 6,
        flagsAndFragment: UInt16 = 0x4000,
        payload: [UInt8] = Array(repeating: 0, count: 20)
    ) -> [UInt8] {
        let headerLength = 20
        let totalLength = headerLength + payload.count
        var packet = [UInt8](repeating: 0, count: totalLength)
        packet[0] = 0x45
        packet[1] = 0
        packet[2] = UInt8((totalLength >> 8) & 0xFF)
        packet[3] = UInt8(totalLength & 0xFF)
        packet[4] = 0
        packet[5] = 0
        packet[6] = UInt8((flagsAndFragment >> 8) & 0xFF)
        packet[7] = UInt8(flagsAndFragment & 0xFF)
        packet[8] = 64
        packet[9] = protocolNumber
        writeUInt32(source, into: &packet, at: 12)
        writeUInt32(destination, into: &packet, at: 16)
        packet.replaceSubrange(20..<totalLength, with: payload)
        let checksum = internetChecksum(packet, range: 0..<headerLength)
        packet[10] = UInt8((checksum >> 8) & 0xFF)
        packet[11] = UInt8(checksum & 0xFF)
        return packet
    }
}

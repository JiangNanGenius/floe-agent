import Foundation

public struct ImportedPacket: Codable, Equatable, Sendable {
    public let timestamp: Date?
    public let linkType: UInt32
    public let interfaceID: UInt32
    public let bytes: Data
    public let originalByteCount: Int
    public var truncated: Bool { bytes.count < originalByteCount }
}
public struct ImportedCapture: Sendable {
    public let origin: CaptureOrigin
    public let packets: [ImportedPacket]
    public let warnings: [String]
    public var events: [CaptureEvent] {
        packets.map { CaptureEvent(bytes: $0.bytes, direction: .observation, layer: .networkPacket, origin: origin,
            timestamp: $0.timestamp, originalByteCount: $0.originalByteCount,
            notes: ["linkType=\($0.linkType)", "interfaceID=\($0.interfaceID)"] + ($0.timestamp == nil ? ["Timestamp unavailable"] : [])) }
    }
}
public enum PacketCaptureImporter {
    public static func parse(_ data: Data, maximumBytes: Int = 64 * 1024 * 1024,
                             maximumPackets: Int = 100_000) throws -> ImportedCapture {
        guard maximumBytes > 0, maximumBytes <= 128 * 1024 * 1024,
              (1...100_000).contains(maximumPackets), data.count <= maximumBytes else { throw ToolboxError.limit("capture import") }
        let magic = Array(data.prefix(4))
        if magic == [0x0a, 0x0d, 0x0d, 0x0a] { return try pcapng(data, maximumPackets: maximumPackets) }
        return try pcap(data, maximumPackets: maximumPackets)
    }
    private static func pcap(_ data: Data, maximumPackets: Int) throws -> ImportedCapture {
        var r = ByteReader(data); let magic = try r.take(4)
        let little: Bool, nanos: Bool
        switch magic {
        case [0xd4, 0xc3, 0xb2, 0xa1]: little = true; nanos = false
        case [0xa1, 0xb2, 0xc3, 0xd4]: little = false; nanos = false
        case [0x4d, 0x3c, 0xb2, 0xa1]: little = true; nanos = true
        case [0xa1, 0xb2, 0x3c, 0x4d]: little = false; nanos = true
        default: throw ToolboxError.invalid("PCAP magic")
        }
        guard try r.u16(little: little) == 2, try r.u16(little: little) == 4 else { throw ToolboxError.unsupported("PCAP version") }
        _ = try r.u32(little: little); _ = try r.u32(little: little)
        let snaplen = try r.u32(little: little), link = try r.u32(little: little) & 0xffff
        guard snaplen > 0, snaplen <= 16 * 1024 * 1024 else { throw ToolboxError.limit("PCAP snapshot length") }
        var packets: [ImportedPacket] = []
        while r.remaining > 0 {
            guard packets.count < maximumPackets else { throw ToolboxError.limit("PCAP packets") }
            let seconds = try r.u32(little: little), fraction = try r.u32(little: little)
            let captured = try r.u32(little: little), original = try r.u32(little: little)
            guard captured <= snaplen, captured <= original, fraction < (nanos ? 1_000_000_000 : 1_000_000) else { throw ToolboxError.invalid("PCAP record header") }
            let payload = try r.take(Int(captured))
            packets.append(ImportedPacket(timestamp: Date(timeIntervalSince1970: Double(seconds) + Double(fraction) / (nanos ? 1e9 : 1e6)),
                linkType: link, interfaceID: 0, bytes: Data(payload), originalByteCount: Int(original)))
        }
        return ImportedCapture(origin: .pcap, packets: packets, warnings: [])
    }
    private struct Interface { var link: UInt32; var snaplen: UInt32; var resolution = 1e-6; var timeOffset: Double = 0 }
    private static func pcapng(_ data: Data, maximumPackets: Int) throws -> ImportedCapture {
        var r = ByteReader(data), little = true, haveSection = false
        var interfaces: [Interface] = [], packets: [ImportedPacket] = [], warnings: [String] = []
        while r.remaining > 0 {
            guard r.remaining >= 12 else { throw ToolboxError.truncated("PCAPNG block") }
            let start = r.offset
            let isSection = Array(r.bytes[start..<start+4]) == [0x0a, 0x0d, 0x0d, 0x0a]
            if isSection {
                let order = Array(r.bytes[start+8..<start+12])
                guard order == [0x4d, 0x3c, 0x2b, 0x1a] || order == [0x1a, 0x2b, 0x3c, 0x4d] else { throw ToolboxError.invalid("PCAPNG byte order") }
                little = order[0] == 0x4d
            }
            guard isSection || haveSection else { throw ToolboxError.invalid("PCAPNG missing section") }
            let type = try r.u32(little: little), total = Int(try r.u32(little: little))
            guard total >= 12, total.isMultiple(of: 4), total - 8 <= r.remaining else { throw ToolboxError.invalid("PCAPNG block length") }
            var body = ByteReader(Data(try r.take(total - 12)))
            guard try r.u32(little: little) == UInt32(total) else { throw ToolboxError.invalid("PCAPNG repeated length") }
            switch type {
            case 0x0a0d0d0a:
                _ = try body.u32(little: little)
                guard try body.u16(little: little) == 1, try body.u16(little: little) == 0 else { throw ToolboxError.unsupported("PCAPNG section version") }
                _ = try body.take(8); interfaces = []; haveSection = true
            case 1:
                guard interfaces.count < 1024 else { throw ToolboxError.limit("PCAPNG interfaces") }
                let link = try body.u16(little: little); _ = try body.u16(little: little)
                var item = Interface(link: UInt32(link), snaplen: try body.u32(little: little))
                while body.remaining > 0 {
                    let code = try body.u16(little: little), length = Int(try body.u16(little: little))
                    if code == 0 { guard length == 0 else { throw ToolboxError.invalid("PCAPNG option") }; break }
                    let value = try body.take(length); _ = try body.take((4-length%4)%4)
                    if code == 9 {
                        guard value.count == 1 else { throw ToolboxError.invalid("timestamp resolution") }
                        let exponent = Int(value[0] & 0x7f)
                        guard exponent <= 63 else { throw ToolboxError.unsupported("timestamp resolution") }
                        item.resolution = pow(value[0] & 0x80 == 0 ? 10.0 : 2.0, -Double(exponent))
                    } else if code == 14 {
                        var offsetReader = ByteReader(Data(value)); guard value.count == 8 else { throw ToolboxError.invalid("timestamp offset") }
                        let a = try offsetReader.u32(little: little), b = try offsetReader.u32(little: little)
                        let bits = little ? UInt64(a) | UInt64(b) << 32 : UInt64(a) << 32 | UInt64(b)
                        item.timeOffset = Double(Int64(bitPattern: bits))
                    }
                }
                interfaces.append(item)
            case 6:
                let id = try body.u32(little: little)
                guard Int(id) < interfaces.count, packets.count < maximumPackets else { throw ToolboxError.invalid("PCAPNG packet interface or count") }
                let item = interfaces[Int(id)], high = try body.u32(little: little), low = try body.u32(little: little)
                let captured = try body.u32(little: little), original = try body.u32(little: little)
                guard captured <= original, item.snaplen == 0 || captured <= item.snaplen else { throw ToolboxError.invalid("PCAPNG captured length") }
                let bytes = Data(try body.take(Int(captured))); _ = try body.take((4-Int(captured)%4)%4)
                let time = Double(UInt64(high) << 32 | UInt64(low)) * item.resolution + item.timeOffset
                guard time.isFinite else { throw ToolboxError.invalid("PCAPNG timestamp") }
                packets.append(ImportedPacket(timestamp: Date(timeIntervalSince1970: time), linkType: item.link, interfaceID: id, bytes: bytes, originalByteCount: Int(original)))
            case 3:
                guard let item = interfaces.first, packets.count < maximumPackets else { throw ToolboxError.invalid("PCAPNG simple packet interface") }
                let original = try body.u32(little: little), captured = item.snaplen == 0 ? original : min(original, item.snaplen)
                let bytes = Data(try body.take(Int(captured))); _ = try body.take((4-Int(captured)%4)%4)
                guard body.remaining == 0 else { throw ToolboxError.invalid("PCAPNG simple packet size") }
                packets.append(ImportedPacket(timestamp: nil, linkType: item.link, interfaceID: 0, bytes: bytes, originalByteCount: Int(original)))
            default:
                if !warnings.contains("Unknown blocks skipped") { warnings.append("Unknown blocks skipped") }
            }
        }
        return ImportedCapture(origin: .pcapng, packets: packets, warnings: warnings)
    }
}

public enum NetworkPacketInspector {
    public static func inspect(_ packet: ImportedPacket) throws -> ProtocolReport {
        var r = ByteReader(packet.bytes); var ipVersion: Int
        if packet.linkType == 1 {
            _ = try r.take(12); var ether = try r.u16(); var tags = 0
            while [0x8100, 0x88a8].contains(ether) {
                guard tags < 2 else { throw ToolboxError.unsupported("VLAN depth") }; tags += 1
                _ = try r.u16(); ether = try r.u16()
            }
            guard [0x0800, 0x86dd].contains(ether) else { return ProtocolReport(name: "Ethernet", summary: "Non-IP frame", fields: ["etherType": String(ether)]) }
            ipVersion = ether == 0x0800 ? 4 : 6
        } else if [101, 228, 229].contains(packet.linkType) {
            guard let first = r.bytes.first else { throw ToolboxError.truncated("IP packet") }; ipVersion = Int(first >> 4)
        } else { return ProtocolReport(name: "Packet", summary: "Unsupported link type", fields: ["linkType": String(packet.linkType)], warnings: ["Raw frame preserved"] ) }
        let start = r.offset; var fields: [String: String] = [:]; var warnings = packet.truncated ? ["Capture truncated"] : []
        let proto: UInt8, length: Int
        if ipVersion == 4 {
            let first = try r.u8(); let header = Int(first & 15) * 4
            guard first >> 4 == 4, header >= 20 else { throw ToolboxError.invalid("IPv4 header") }
            _ = try r.u8(); length = Int(try r.u16()); _ = try r.u16(); let fragment = try r.u16()
            _ = try r.u8(); proto = try r.u8(); _ = try r.u16()
            fields["source"] = try r.take(4).map(String.init).joined(separator: ".")
            fields["destination"] = try r.take(4).map(String.init).joined(separator: ".")
            guard length >= header else { throw ToolboxError.invalid("IPv4 total length") }; _ = try r.take(header-20)
            if fragment & 0x3fff != 0 { return ProtocolReport(name: "IPv4", summary: "Fragment; no transport inference", fields: fields, warnings: ["IP reassembly required"]) }
        } else if ipVersion == 6 {
            guard try r.u8() >> 4 == 6 else { throw ToolboxError.invalid("IPv6 version") }
            _ = try r.take(3); length = Int(try r.u16()) + 40; proto = try r.u8(); _ = try r.u8()
            let source = try r.take(16), destination = try r.take(16)
            fields["source"] = stride(from: 0, to: 16, by: 2).map { String(UInt16(source[$0]) << 8 | UInt16(source[$0+1]), radix: 16) }.joined(separator: ":")
            fields["destination"] = stride(from: 0, to: 16, by: 2).map { String(UInt16(destination[$0]) << 8 | UInt16(destination[$0+1]), radix: 16) }.joined(separator: ":")
        } else { throw ToolboxError.unsupported("IP version") }
        if start + length > r.bytes.count { warnings.append("IP payload truncated") }
        let available = max(0, min(start+length, r.bytes.count)-r.offset)
        var transport = ByteReader(Data(try r.take(available)))
        fields["ipProtocol"] = String(proto)
        if [6, 17].contains(proto) {
            fields["sourcePort"] = String(try transport.u16()); fields["destinationPort"] = String(try transport.u16())
            if proto == 6 {
                fields["sequence"] = String(try transport.u32()); _ = try transport.u32()
                let header = Int(try transport.u8() >> 4) * 4; fields["flags"] = String(try transport.u8())
                guard header >= 20 else { throw ToolboxError.invalid("TCP header size") }; _ = try transport.take(header-14)
                fields["payloadHex"] = Data(try transport.take(transport.remaining)).hex
                warnings.append("TCP packet payload is not an application message; ordered stream reassembly may be required")
            } else {
                let size = Int(try transport.u16()); _ = try transport.u16()
                guard size >= 8 else { throw ToolboxError.invalid("UDP length") }
                if size-8 > transport.remaining { warnings.append("UDP datagram truncated") }
                fields["payloadHex"] = Data(try transport.take(min(size-8, transport.remaining))).hex
            }
        }
        return ProtocolReport(name: proto == 6 ? "TCP" : proto == 17 ? "UDP" : "IP", summary: "Imported network packet", fields: fields, warnings: warnings)
    }
}

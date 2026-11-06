import Foundation
import Testing
@testable import FloeToolboxCore

private func u16(_ n: UInt16, little: Bool) -> Data { Data(little ? [UInt8(n & 255), UInt8(n >> 8)] : [UInt8(n >> 8), UInt8(n & 255)]) }
private func u32(_ n: UInt32, little: Bool) -> Data { let b = [UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8(n >> 24)]; return Data(little ? b : b.reversed()) }
private func pcap(_ payload: Data, little: Bool = true) -> Data {
    var data = little ? Data([0xd4,0xc3,0xb2,0xa1]) : Data([0xa1,0xb2,0xc3,0xd4])
    data += u16(2,little:little)+u16(4,little:little)+u32(0,little:little)+u32(0,little:little)+u32(65535,little:little)+u32(1,little:little)
    data += u32(100,little:little)+u32(500000,little:little)+u32(UInt32(payload.count),little:little)+u32(UInt32(payload.count),little:little)+payload
    return data
}
private func block(_ type: UInt32, _ body: Data, little: Bool = true) -> Data {
    let count = UInt32(body.count+12)
    return u32(type,little:little)+u32(count,little:little)+body+u32(count,little:little)
}
private func pcapng(_ payload: Data, little: Bool = true) -> Data {
    let section = block(0x0a0d0d0a,u32(0x1a2b3c4d,little:little)+u16(1,little:little)+u16(0,little:little)+Data(repeating:255,count:8),little:little)
    let interface = block(1,u16(1,little:little)+u16(0,little:little)+u32(65535,little:little),little:little)
    let pad = Data(repeating:0,count:(4-payload.count%4)%4)
    let packetBody = u32(0,little:little)+u32(0,little:little)+u32(2_000_000,little:little)+u32(UInt32(payload.count),little:little)+u32(UInt32(payload.count),little:little)+payload+pad
    return section+interface+block(6,packetBody,little:little)
}
@Test func captureFormatsAndEndianness() throws {
    for little in [true,false] {
        let payload = Data([1,2,3,4,5])
        let classic = try PacketCaptureImporter.parse(pcap(payload,little:little))
        #expect(classic.packets[0].bytes == payload)
        #expect(classic.packets[0].timestamp?.timeIntervalSince1970 == 100.5)
        let next = try PacketCaptureImporter.parse(pcapng(payload,little:little))
        #expect(next.packets[0].bytes == payload)
        #expect(next.packets[0].timestamp?.timeIntervalSince1970 == 2)
        #expect(next.events[0].layer == .networkPacket)
    }
}
@Test func truncatedCapturesAndBadTrailersNeverTrap() throws {
    let original = pcapng(Data([1,2,3]))
    for count in 0..<original.count {
        let prefix = Data(original.prefix(count))
        if count == 28 || count == 48 { continue } // Complete sections without packets are legitimate.
        do { let result = try PacketCaptureImporter.parse(prefix); #expect(result.packets.isEmpty) } catch { }
    }
    var corrupt = original; corrupt[corrupt.count-1] = 1
    #expect(throws: ToolboxError.self) { try PacketCaptureImporter.parse(corrupt) }
    #expect(throws: ToolboxError.self) { try PacketCaptureImporter.parse(pcap(Data([1,2,3])),maximumBytes:8) }
}
@Test func pcapngSectionsResetInterfaces() throws {
    let file = pcapng(Data([1])) + pcapng(Data([2]),little:false)
    let parsed = try PacketCaptureImporter.parse(file)
    #expect(parsed.packets.map(\.bytes) == [Data([1]),Data([2])])
}
@Test func realUDPFrameInspection() throws {
    let ethernet = Data(repeating:0,count:12)+Data([8,0])
    let ipv4 = Data([0x45,0,0,31,0,0,0,0,64,17,0,0,192,0,2,1,192,0,2,2])
    let udp = Data([0x23,0x28,0x23,0x29,0,11,0,0,65,66,67])
    let packet = ImportedPacket(timestamp:nil,linkType:1,interfaceID:0,bytes:ethernet+ipv4+udp,originalByteCount:45)
    let report = try NetworkPacketInspector.inspect(packet)
    #expect(report.name == "UDP"); #expect(report.fields["sourcePort"] == "9000")
    #expect(report.fields["payloadHex"] == "41 42 43")
}
@Test func journalRollingRecoveryAndSnapshots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repository = try FileCaptureRepository(root:root), owner = UUID(), id = UUID()
    let limits = try CaptureLimits(maximumRecords:2,maximumBytes:6,maximumRecordBytes:4)
    let journal = try CaptureJournal(ownerID:owner,captureID:id,repository:repository,limits:limits)
    try await journal.append([CaptureEvent(bytes:Data([1,2,3]),direction:.sent)])
    let saved = try await journal.saveSnapshot()
    let savedBytes = try Data(contentsOf:saved)
    try await journal.append([CaptureEvent(bytes:Data([4,5,6]),direction:.received),CaptureEvent(bytes:Data([7,8,9]),direction:.received)])
    let state = await journal.snapshot()
    #expect(state.records.count == 2); #expect(state.droppedRecords == 1)
    #expect(try Data(contentsOf:saved) == savedBytes)
    let restored = try CaptureJournal(ownerID:owner,captureID:id,repository:repository,limits:limits)
    #expect(await restored.snapshot() == state)
    let exported = try await journal.exportJSONLines()
    #expect(String(data:exported,encoding:.utf8)?.contains("floe.capture.jsonl") == true)
}
@Test func journalCASConflictAndCorruptionPreservation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repository = try FileCaptureRepository(root:root), owner = UUID(), id = UUID(), limits = try CaptureLimits()
    let a = try CaptureJournal(ownerID:owner,captureID:id,repository:repository,limits:limits)
    let b = try CaptureJournal(ownerID:owner,captureID:id,repository:repository,limits:limits)
    try await a.append([CaptureEvent(bytes:Data([1]),direction:.sent)])
    await #expect(throws: ToolboxError.revisionConflict) { try await b.append([CaptureEvent(bytes:Data([2]),direction:.sent)]) }
    try await b.reload(); try await b.append([CaptureEvent(bytes:Data([2]),direction:.sent)])
    let file = root.appendingPathComponent("capture-\(id.uuidString).json")
    let corrupt = Data("broken record".utf8); try corrupt.write(to:file)
    #expect(throws: ToolboxError.corruptStore) { try repository.load(captureID:id,ownerID:owner) }
    #expect(try Data(contentsOf:file) == corrupt)
}
@Test func credentialsAreOmittedBeforePersistence() async throws {
    let redactor = CaptureRedactor(knownSecrets:[Data("private-key".utf8)])
    for bytes in [Data("Authorization: Bearer example".utf8),Data("private-key".utf8),Data([0x10,0])] {
        let event = redactor.sanitize(bytes,wireProtocol:.mqtt5)
        #expect(event.redacted); #expect(event.bytes.isEmpty); #expect(event.originalByteCount == bytes.count)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let journal = try CaptureJournal(ownerID:UUID(),repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let binaryHeader = Data([0xff,0,0xfe]) + Data("Authorization: Bearer fixture".utf8)
    try await journal.append([CaptureEvent(bytes:binaryHeader,direction:.observation,origin:.pcap)])
    #expect(await journal.snapshot().records.first?.redacted == true)
    #expect(await journal.snapshot().records.first?.bytes.isEmpty == true)
    let snapshot = try await journal.saveSnapshot()
    let saved = try String(contentsOf:snapshot,encoding:.utf8)
    #expect(!saved.contains("Bearer fixture"))
}

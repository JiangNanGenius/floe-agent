import Foundation
import FloeToolboxCore
import FloeToolboxUSBWire
import FloeToolboxUSBIOKit

public enum USBClientError: Error, Equatable, Sendable { case unavailable, invalidPacket, detached, busy, limit, io(Int32) }
/// The production host opens an explicitly selected, entitled user client; no first-device fallback.
public protocol USBUserClientChannel: Sendable {
    func exchange(_ request: Data, maximumReplyBytes: Int) async throws -> Data
    func close() async
}
public struct USBDeviceInformation: Sendable {
    public let vendor: UInt16; public let product: UInt16
    public let interfaceNumber: UInt8; public let controlInterface: UInt8
    public let interfaceClass: UInt8; public let interfaceSubclass: UInt8
    public let maximumPacketSize: UInt16
    public let family: USBSerialFamily?
    public let pl2303Revision: PL2303Revision?
    public let generation: UInt64
    fileprivate init(_ info: FloeUSBDeviceInfo, generation: UInt64) {
        vendor = info.vendor; product = info.product; interfaceNumber = info.interfaceNumber
        interfaceClass = info.interfaceClass; interfaceSubclass = info.interfaceSubclass
        controlInterface = info.controlInterface; maximumPacketSize = info.maximumPacketSize; self.generation = generation
        if info.interfaceClass == 10, info.controlInterface != info.interfaceNumber { family = .cdcACM }
        else { family = USBSerialChipPlans.candidate(vendor:info.vendor,product:info.product,interfaceClass:info.interfaceClass,subclass:info.interfaceSubclass) }
        pl2303Revision = PL2303Revision.identify(deviceClass:info.deviceClass,controlPacketSize:info.controlPacketSize,usbVersion:info.usbVersion,deviceVersion:info.deviceVersion)
    }
}
public actor USBUserClientExecutor: USBTransferExecutor {
    private let channel: any USBUserClientChannel
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 1
    private var closed = false
    private var active = false
    public init(channel: any USBUserClientChannel) { self.channel = channel }
    private func request(operation: UInt16, payload: Data = Data(), capacity: Int = 0,
                         control: USBControlRequest? = nil) async throws -> (FloeUSBResponse,Data) {
        guard !closed else { throw USBClientError.detached }; guard !active else { throw USBClientError.busy }
        guard payload.count <= Int(FLOE_USB_MAX_PAYLOAD), (0...Int(FLOE_USB_MAX_PAYLOAD)).contains(capacity), nextID < UInt64.max else { throw USBClientError.limit }
        active = true; defer { active = false }
        var header = FloeUSBRequest()
        header.magic = FLOE_USB_MAGIC; header.version = UInt16(FLOE_USB_VERSION); header.operation = operation
        header.generation = operation == FLOE_USB_OP_INFO ? 0 : generation; header.requestID = nextID; nextID += 1
        header.timeoutMS = 1000; header.payloadSize = UInt32(payload.count); header.capacity = UInt32(capacity)
        if let control { header.requestType = control.requestType; header.request = control.request; header.value = control.value; header.index = control.index }
        var bytes = withUnsafeBytes(of:header) { Data($0) }; bytes += payload
        var verified = FloeUSBRequest()
        guard bytes.withUnsafeBytes({ floe_usb_validate_request($0.baseAddress,$0.count,&verified) }) else { throw USBClientError.invalidPacket }
        let response = try await channel.exchange(bytes,maximumReplyBytes:MemoryLayout<FloeUSBResponse>.size+capacity)
        guard !closed, !Task.isCancelled else { throw USBClientError.detached }
        var reply = FloeUSBResponse()
        guard response.withUnsafeBytes({ floe_usb_validate_response($0.baseAddress,$0.count,&header,&reply) }) else { await close(); throw USBClientError.invalidPacket }
        guard reply.status == 0 else { throw USBClientError.io(reply.status) }
        if operation == FLOE_USB_OP_INFO { generation = reply.generation }
        return (reply,Data(response.dropFirst(MemoryLayout<FloeUSBResponse>.size)))
    }
    public func information() async throws -> USBDeviceInformation {
        let (reply,data) = try await request(operation:UInt16(FLOE_USB_OP_INFO),capacity:MemoryLayout<FloeUSBDeviceInfo>.size)
        guard data.count == MemoryLayout<FloeUSBDeviceInfo>.size else { throw USBClientError.invalidPacket }
        let info = data.withUnsafeBytes { $0.loadUnaligned(as:FloeUSBDeviceInfo.self) }
        guard info.maximumPacketSize >= 2, info.maximumPacketSize <= 1024, info.inputEndpoint&0x80 != 0,
              info.outputEndpoint&0x80 == 0, info.inputEndpoint&15 != 0, info.outputEndpoint&15 != 0 else { await close(); throw USBClientError.invalidPacket }
        return USBDeviceInformation(info,generation:reply.generation)
    }
    public func control(_ value: USBControlRequest) async throws -> Data {
        let (_,bytes) = try await request(operation:UInt16(FLOE_USB_OP_CONTROL),payload:value.payload,capacity:Int(value.expectedReadBytes),control:value)
        return bytes
    }
    public func write(_ bytes: Data) async throws -> Int {
        guard bytes.count <= 65536 else { throw USBClientError.limit }; if bytes.isEmpty { return 0 }
        var sent = 0
        while sent < bytes.count {
            try Task.checkCancellation()
            let chunk = Data(bytes.dropFirst(sent).prefix(Int(FLOE_USB_MAX_PAYLOAD)))
            let (reply,_) = try await request(operation:UInt16(FLOE_USB_OP_WRITE),payload:chunk)
            sent += Int(reply.actual)
            if Int(reply.actual) != chunk.count { return sent } // Core reports a short write; never replay.
        }
        return sent
    }
    public func read(maximumBytes: Int) async throws -> Data {
        guard (1...65536).contains(maximumBytes) else { throw USBClientError.limit }
        let (_,bytes) = try await request(operation:UInt16(FLOE_USB_OP_READ),capacity:min(maximumBytes,Int(FLOE_USB_MAX_PAYLOAD)))
        return bytes
    }
    public func close() async { guard !closed else { return }; closed = true; generation = 0; await channel.close() }
}

/// IOConnectCallStructMethod runs on a private queue, never the UI/cooperative executor.
/// Each packet is below 4 KiB, so large shared-memory descriptors are not accepted by the driver.
public final class IOKitUSBUserClientChannel: USBUserClientChannel, @unchecked Sendable {
    private let queue = DispatchQueue(label:"floe.toolbox.usb-user-client")
    private var connection: UInt32
    private var closed = false
    private init(connection: UInt32) { self.connection = connection }
    // Native selection holds the complete observed identity; no raw-ID bypass.
    static func open(expectedIdentity: USBRegistryIdentity) async throws -> IOKitUSBUserClientChannel {
        try Task.checkCancellation()
        let channel: IOKitUSBUserClientChannel = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.utility).async { continuation.resume(with:Result { try openSynchronously(expectedIdentity: expectedIdentity) }) }
        }
        if Task.isCancelled { await channel.close(); throw CancellationError() }; return channel
    }
    private static func openSynchronously(expectedIdentity: USBRegistryIdentity) throws -> IOKitUSBUserClientChannel {
        var raw = expectedIdentity.raw
        var connection: UInt32 = 0
        try USBRegistryError.check(floe_usb_host_open(&raw, &connection))
        guard connection != 0 else { throw USBRegistryError.identityUnavailable }
        return IOKitUSBUserClientChannel(connection:connection)
    }
    public func exchange(_ request: Data, maximumReplyBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        guard request.count <= MemoryLayout<FloeUSBRequest>.size+Int(FLOE_USB_MAX_PAYLOAD),
              (MemoryLayout<FloeUSBResponse>.size...MemoryLayout<FloeUSBResponse>.size+Int(FLOE_USB_MAX_PAYLOAD)).contains(maximumReplyBytes) else { throw USBClientError.limit }
        return try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard !closed else { continuation.resume(throwing:USBClientError.detached); return }
            var result = Data(count:maximumReplyBytes), count = maximumReplyBytes
            let status = request.withUnsafeBytes { input in result.withUnsafeMutableBytes { output in
                floe_usb_host_exchange(connection,input.baseAddress,input.count,output.baseAddress,&count)
            } }
            do { try USBRegistryError.check(status) }
            catch { continuation.resume(throwing: error); return }
            guard (0...result.count).contains(count) else { continuation.resume(throwing: USBClientError.invalidPacket); return }
            result.count = count; continuation.resume(returning:result)
        } }
    }
    public func close() async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if !closed { closed = true; floe_usb_host_close(connection); connection = 0 }; continuation.resume()
        } }
    }
    deinit { if connection != 0 { floe_usb_host_close(connection) } }
}

public enum USBSerialClient {
    public static func connect(channel: any USBUserClientChannel, settings: USBSerialSettings) async throws -> USBSerialConnection {
        try await connectValidated(channel: channel, settings: settings, expectedIdentity: nil)
    }
    static func connect(channel: any USBUserClientChannel, settings: USBSerialSettings,
                        expectedIdentity: USBRegistryIdentity) async throws -> USBSerialConnection {
        try await connectValidated(channel: channel, settings: settings, expectedIdentity: expectedIdentity)
    }
    private static func connectValidated(channel: any USBUserClientChannel, settings: USBSerialSettings,
                                          expectedIdentity: USBRegistryIdentity?) async throws -> USBSerialConnection {
        let executor = USBUserClientExecutor(channel:channel)
        do {
            try Task.checkCancellation()
            let info = try await executor.information()
            try Task.checkCancellation()
            if let expectedIdentity, !expectedIdentity.matchesInformation(info) { throw USBRegistryError.staleSelection }
            guard let family = info.family, family != .pl2303 || info.pl2303Revision != nil else { throw USBClientError.unavailable }
            let connection = try USBSerialConnection(executor:executor,family:family,maximumPacketSize:Int(info.maximumPacketSize),
                ftdiPortIndexed:family == .ftdi && [0x6010,0x6011,0x6014].contains(info.product),pl2303Revision:info.pl2303Revision)
            try await connection.configure(settings,interface:family == .cdcACM ? info.controlInterface : info.interfaceNumber)
            try Task.checkCancellation()
            return connection
        } catch { await executor.close(); throw error }
    }
}

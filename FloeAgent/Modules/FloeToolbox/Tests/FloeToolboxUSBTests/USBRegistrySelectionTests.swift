import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUSBWire
import FloeToolboxUSBIOKit
@testable import FloeToolboxUSB

// Synthetic registry/IPC fixtures only. Never enumerate or open native IOKit.
private func match(interface: UInt8 = 0) -> USBDriverInterfaceMatch {
    .init(vendorID: 0x10c4, productID: 0xea60, configurationValue: 1,
          interfaceNumber: interface, interfaceClass: 255, interfaceSubclass: 0, interfaceProtocol: 0)
}
private func observation(service: UInt64 = 11, provider: UInt64 = 21, device: UInt64 = 31,
                         interface: UInt8 = 0, configuration: UInt8 = 1, protocol_: UInt8 = 0) throws -> USBRegistryIdentity {
    var raw = FloeUSBRegistryIdentity()
    raw.serviceID = service; raw.providerID = provider; raw.deviceID = device
    raw.vendor = 0x10c4; raw.product = 0xea60; raw.configuration = configuration
    raw.interfaceNumber = interface; raw.interfaceClass = 255; raw.interfaceProtocol = protocol_
    return try USBRegistryIdentity(raw: raw)
}
private actor RegistryFixtureChannel: USBUserClientChannel {
    private(set) var operations: [UInt16] = []
    private(set) var closed = false
    let interface: UInt8
    init(interface: UInt8 = 0) { self.interface = interface }
    func exchange(_ bytes: Data, maximumReplyBytes: Int) throws -> Data {
        guard !closed else { throw USBClientError.detached }
        var request = FloeUSBRequest()
        guard bytes.withUnsafeBytes({ floe_usb_validate_request($0.baseAddress, $0.count, &request) }) else {
            throw USBClientError.invalidPacket
        }
        operations.append(request.operation)
        var payload = Data(), actual: UInt32 = 0
        if request.operation == FLOE_USB_OP_INFO {
            var info = FloeUSBDeviceInfo()
            info.vendor = 0x10c4; info.product = 0xea60; info.interfaceNumber = interface; info.interfaceClass = 255
            info.inputEndpoint = 0x81; info.outputEndpoint = 2; info.maximumPacketSize = 64
            payload = withUnsafeBytes(of: info) { Data($0) }; actual = UInt32(payload.count)
        } else if request.operation == FLOE_USB_OP_CONTROL || request.operation == FLOE_USB_OP_WRITE {
            actual = request.payloadSize
        } else { throw USBClientError.invalidPacket }
        var response = FloeUSBResponse()
        response.magic = FLOE_USB_MAGIC; response.version = UInt16(FLOE_USB_VERSION)
        response.operation = request.operation; response.requestID = request.requestID
        response.generation = 9; response.actual = actual
        let result = withUnsafeBytes(of: response) { Data($0) } + payload
        guard result.count <= maximumReplyBytes else { throw USBClientError.invalidPacket }
        return result
    }
    func close() { closed = true }
}
private actor RegistryFixtureBackend: USBRegistryBackend {
    var observations: [USBRegistryIdentity]
    let channel: RegistryFixtureChannel
    var failure: USBRegistryError?
    private(set) var opened: [USBRegistryIdentity] = []
    private(set) var discoveries = 0
    var cancelAfterOpen = false
    init(_ observations: [USBRegistryIdentity], channel: RegistryFixtureChannel = RegistryFixtureChannel()) {
        self.observations = observations; self.channel = channel
    }
    func replace(_ values: [USBRegistryIdentity]) { observations = values }
    func fail(_ error: USBRegistryError) { failure = error }
    func cancelWhenOpening() { cancelAfterOpen = true }
    func discover() throws -> [USBRegistryIdentity] {
        discoveries += 1; if let failure { throw failure }; return observations
    }
    func open(expected: USBRegistryIdentity) throws -> any USBUserClientChannel {
        opened.append(expected)
        guard observations.contains(expected) else { throw USBRegistryError.staleSelection }
        if cancelAfterOpen { withUnsafeCurrentTask { $0?.cancel() } }
        return channel
    }
}

@Test func registryRequiresIncludedConfiguredPayloadAndPreservesNativeErrorKinds() async throws {
    #expect(throws: USBRegistryError.packageNotIncluded) { _ = try USBRegistryHost(package: .notIncluded) }
    #expect(throws: USBRegistryError.packageUnconfigured) { _ = try USBRegistryHost(package: .unconfigured) }
    #expect(throws: USBRegistryError.invalidPackage) { _ = try USBRegistryHost(package: .invalid("fixture")) }
    #expect(throws: USBRegistryError.unsupported) { try USBRegistryError.check(Int32(FLOE_USB_HOST_UNSUPPORTED)) }
    #expect(throws: USBRegistryError.io(-536870207)) { try USBRegistryError.check(-536870207) }
    let backend = RegistryFixtureBackend([])
    let host = try USBRegistryHost(matches: [match()], backend: backend)
    let empty = try await host.discover()
    #expect(empty.devices.isEmpty && empty.unmatchedOwnServiceCount == 0)
    await backend.fail(.unsupported)
    await #expect(throws: USBRegistryError.unsupported) { _ = try await host.discover() }
}

@Test func explicitRegistrySelectionNeverChoosesFirstIdenticalVendorProduct() async throws {
    let first = try observation(), second = try observation(service: 12, provider: 22, device: 32)
    let backend = RegistryFixtureBackend([second, first])
    let host = try USBRegistryHost(matches: [match()], backend: backend)
    let snapshot = try await host.discover()
    #expect(snapshot.devices.map(\.id) == [11, 12])
    #expect(throws: USBRegistryError.staleSelection) { _ = try snapshot.select(registryEntryID: 99) }
    let selection = try snapshot.select(registryEntryID: 12)
    let connection = try await host.connect(selection: selection, settings: USBSerialSettings())
    #expect(await backend.opened == [second])
    #expect(await backend.channel.operations == [UInt16(FLOE_USB_OP_INFO)] + Array(repeating: UInt16(FLOE_USB_OP_CONTROL), count: 4))
    try await connection.send(Data([1, 2]))
    #expect(await backend.channel.operations.last == UInt16(FLOE_USB_OP_WRITE))
    await connection.close()
    #expect(await backend.channel.closed)
}

@Test func exactConfigurationProtocolAndInterfaceFilterExposeUnmatchedOwnServices() async throws {
    let backend = RegistryFixtureBackend([
        try observation(), try observation(service: 12, configuration: 2),
        try observation(service: 13, protocol_: 1), try observation(service: 14, interface: 1)
    ])
    let host = try USBRegistryHost(matches: [match()], backend: backend)
    let snapshot = try await host.discover()
    #expect(snapshot.devices.map(\.id) == [11])
    #expect(snapshot.unmatchedOwnServiceCount == 3)
    #expect(throws: USBRegistryError.staleSelection) { _ = try snapshot.select(registryEntryID: 13) }
}

@Test func selectionFromAnotherHostIsRejectedBeforeOpeningAnyChannel() async throws {
    let value = try observation(), backendA = RegistryFixtureBackend([value]), backendB = RegistryFixtureBackend([value])
    let a = try USBRegistryHost(matches: [match()], backend: backendA)
    let b = try USBRegistryHost(matches: [match()], backend: backendB)
    let snapshot = try await a.discover(), selected = try snapshot.select(registryEntryID: value.serviceID)
    await #expect(throws: USBRegistryError.staleSelection) {
        _ = try await b.connect(selection: selected, settings: USBSerialSettings())
    }
    let openedA = await backendA.opened, openedB = await backendB.opened
    #expect(openedA.isEmpty && openedB.isEmpty)
}

@Test func changedProviderAtOpenRejectsStaleSelectionWithoutIssuingINFO() async throws {
    let before = try observation(), after = try observation(provider: 999)
    let backend = RegistryFixtureBackend([before]), host = try USBRegistryHost(matches: [match()], backend: backend)
    let snapshot = try await host.discover(), selected = try snapshot.select(registryEntryID: before.serviceID)
    await backend.replace([after])
    await #expect(throws: USBRegistryError.staleSelection) {
        _ = try await host.connect(selection: selected, settings: USBSerialSettings())
    }
    #expect(await backend.channel.operations.isEmpty)
}

@Test func actualINFOIdentityMismatchClosesBeforeSerialConfiguration() async throws {
    let value = try observation(), channel = RegistryFixtureChannel(interface: 1)
    let backend = RegistryFixtureBackend([value], channel: channel)
    let host = try USBRegistryHost(matches: [match()], backend: backend)
    let snapshot = try await host.discover(), selected = try snapshot.select(registryEntryID: value.serviceID)
    await #expect(throws: USBRegistryError.staleSelection) {
        _ = try await host.connect(selection: selected, settings: USBSerialSettings())
    }
    #expect(await channel.operations == [UInt16(FLOE_USB_OP_INFO)])
    #expect(await channel.closed)
}

@Test func cancellationAfterChannelOpenClosesBeforeIssuingINFO() async throws {
    let value = try observation(), backend = RegistryFixtureBackend([value])
    let host = try USBRegistryHost(matches: [match()], backend: backend)
    let snapshot = try await host.discover(), selected = try snapshot.select(registryEntryID: value.serviceID)
    await backend.cancelWhenOpening()
    let work = Task { try await host.connect(selection: selected, settings: USBSerialSettings()) }
    await #expect(throws: CancellationError.self) { _ = try await work.value }
    #expect(await backend.channel.closed)
    #expect(await backend.channel.operations.isEmpty)
}

@Test func discoveryBudgetAndDuplicateIdentitiesFailRatherThanReturningPartialList() async throws {
    let value = try observation(), backend = RegistryFixtureBackend([value, value])
    let host = try USBRegistryHost(matches: [match()], backend: backend)
    await #expect(throws: USBRegistryError.identityUnavailable) { _ = try await host.discover() }
    await backend.replace(try (1...33).map { try observation(service: UInt64($0)) })
    await #expect(throws: USBRegistryError.limit) { _ = try await host.discover() }
}

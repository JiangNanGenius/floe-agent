// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeTools
import FloeToolboxHost
import FloeToolboxCore
import FloeToolboxUSBWire
import FloeToolboxUSBIOKit
@testable import FloeToolboxUSB
@testable import FloeApp

// All USB registry and IPC facts below are synthetic. No native registry call,
// driver permission, physical port, networking or model provider is exercised.
private actor AppUSBChannel: USBUserClientChannel {
    private(set) var closed = false
    private(set) var writes: [Data] = []
    private(set) var controls: [UInt8] = []
    private var nextRead = Data("fixture-secret".utf8)
    func exchange(_ bytes: Data, maximumReplyBytes: Int) throws -> Data {
        guard !closed else { throw USBClientError.detached }
        var request = FloeUSBRequest()
        guard bytes.withUnsafeBytes({ floe_usb_validate_request($0.baseAddress, $0.count, &request) }) else { throw USBClientError.invalidPacket }
        var payload = Data(), count: UInt32 = 0
        if request.operation == FLOE_USB_OP_INFO {
            var info = FloeUSBDeviceInfo()
            info.vendor = 0x10c4; info.product = 0xea60; info.interfaceClass = 255
            info.inputEndpoint = 0x81; info.outputEndpoint = 2; info.maximumPacketSize = 64
            payload = withUnsafeBytes(of: info) { Data($0) }; count = UInt32(payload.count)
        } else if request.operation == FLOE_USB_OP_READ {
            payload = nextRead; count = UInt32(payload.count)
        } else if request.operation == FLOE_USB_OP_WRITE {
            let content = Data(bytes.dropFirst(MemoryLayout<FloeUSBRequest>.size))
            writes.append(content); count = UInt32(content.count)
            if content == Data(":070600091234A4\r\n".utf8) { nextRead = content }
            if content == Data(":070300090001EC\r\n".utf8) { nextRead = Data(":0703021234AE\r\n".utf8) }
        } else if request.operation == FLOE_USB_OP_CONTROL {
            controls.append(request.request)
            count = request.payloadSize
        }
        else { throw USBClientError.invalidPacket }
        var response = FloeUSBResponse()
        response.magic = FLOE_USB_MAGIC; response.version = UInt16(FLOE_USB_VERSION)
        response.operation = request.operation; response.requestID = request.requestID
        response.generation = 7; response.actual = count
        let reply = withUnsafeBytes(of: response) { Data($0) } + payload
        guard reply.count <= maximumReplyBytes else { throw USBClientError.invalidPacket }
        return reply
    }
    func close() { closed = true }
}
private actor AppUSBBackend: USBRegistryBackend {
    let records: [USBRegistryIdentity]
    let channel = AppUSBChannel()
    private(set) var opened = 0
    private(set) var selectedServiceID: UInt64?
    private var hold = false
    private var held: CheckedContinuation<[USBRegistryIdentity], any Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(records: [USBRegistryIdentity]) { self.records = records }
    func holdDiscovery() { hold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func releaseDiscovery() { let value = held; held = nil; value?.resume(returning: records) }
    func discover() async throws -> [USBRegistryIdentity] {
        if !hold { return records }
        return try await withCheckedThrowingContinuation { continuation in
            held = continuation
            let waiting = waiters; waiters.removeAll(); for waiter in waiting { waiter.resume() }
        }
    }
    func open(expected: USBRegistryIdentity) throws -> any USBUserClientChannel {
        guard records.contains(expected) else { throw USBRegistryError.staleSelection }
        opened += 1; selectedServiceID = expected.serviceID; return channel
    }
}
@MainActor private func appUSBFixture() throws -> (ToolboxUSBDevices, AppUSBBackend) {
    let match = USBDriverInterfaceMatch(vendorID: 0x10c4, productID: 0xea60, configurationValue: 1,
        interfaceNumber: 0, interfaceClass: 255, interfaceSubclass: 0, interfaceProtocol: 0)
    let records = try [UInt64(101), 102].map { id in
        var raw = FloeUSBRegistryIdentity()
        raw.serviceID = id; raw.providerID = id + 100; raw.deviceID = id + 200
        raw.vendor = 0x10c4; raw.product = 0xea60; raw.configuration = 1; raw.interfaceClass = 255
        return try USBRegistryIdentity(raw: raw)
    }
    let backend = AppUSBBackend(records: records), host = try USBRegistryHost(matches: [match], backend: backend)
    let package = USBDriverPackageInspection.bundledUnverified(.init(bundleIdentifier: USBDriverPackage.bundleIdentifier,
        minimumDriverKitVersion: USBDriverPackage.minimumDriverKitVersion, wireVersion: Int(FLOE_USB_VERSION), matches: [match]))
    return (ToolboxUSBDevices(inspect: { package }, makeSource: { _ in NativeToolboxUSBSource(host: host) }), backend)
}

@Suite("Native USB App handoff", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ToolboxUSBAppIntegrationTests {
    @Test func missingPackageRemainsNotIncludedAndCannotInvokeDiscoveryFactory() async {
        var factories = 0
        let devices = ToolboxUSBDevices(inspect: { .notIncluded }, makeSource: { _ in
            factories += 1; throw ToolboxUSBFailure.failed
        })
        await devices.refresh().value
        guard case .failed(.notIncluded) = devices.state else { Issue.record("Expected actual notIncluded state"); return }
        #expect(throws: ToolboxUSBFailure.notIncluded) { try devices.validateSelection(nil) }
        #expect(factories == 0 && !devices.canDiscover && !devices.canConnect)
        #expect(ToolboxUSBFailure.from(USBRegistryError.io(-536870207)) == .system(-536870207))
    }
    @Test func nativeChoiceIsRequiredAndChangingAwayThenBackInvalidatesOldRequest() async throws {
        let (devices, backend) = try appUSBFixture()
        await devices.refresh().value
        #expect(devices.devices.map(\.id) == [101, 102] && devices.selectedID == nil)
        #expect(throws: ToolboxUSBFailure.chooseDevice) { _ = try devices.request(settings: USBSerialSettings()) }
        devices.select(102)
        let old = try devices.request(settings: USBSerialSettings())
        try devices.validateSelection(old)
        let (other, otherBackend) = try appUSBFixture()
        await other.refresh().value
        other.select(102)
        #expect(throws: ToolboxUSBFailure.changedDevice) { try other.validateSelection(old) }
        #expect(await otherBackend.opened == 0)
        devices.select(101); devices.select(102)
        #expect(throws: ToolboxUSBFailure.changedDevice) { try devices.validateSelection(old) }
        #expect(await backend.opened == 0)
        devices.reset()
        #expect(devices.selectedID == nil && !devices.canConnect)
    }
    @Test func leaveDuringDiscoveryRejectsLateCompletionWithoutChangingNewState() async throws {
        let (devices, backend) = try appUSBFixture()
        await backend.holdDiscovery()
        let work = devices.refresh()
        await backend.waitUntilHeld()
        devices.reset()
        await backend.releaseDiscovery(); await work.value
        guard case .ready = devices.state else { Issue.record("Late cancelled discovery changed reset state"); return }
        #expect(devices.devices.isEmpty && devices.selectedID == nil)
        #expect(await backend.opened == 0)
    }
    @Test func serialSettingsRejectInvalidValuesBeforeAnyUSBOpen() throws {
        var setup = ToolboxConnectionSetup()
        setup.usbBaud = "0"
        #expect(throws: ToolboxUSBFailure.invalidSettings) { _ = try setup.usbSettings() }
        setup.usbBaud = "115200"; setup.usbParity = 255
        #expect(throws: ToolboxUSBFailure.invalidSettings) { _ = try setup.usbSettings() }
        setup.usbParity = 2; setup.usbDataBits = 7; setup.usbStopBits = 2
        let settings = try setup.usbSettings()
        #expect(settings.baud == 115200 && settings.dataBits == 7 && settings.stopBits == 2 && settings.parity == .even)
    }
    @Test func serialAssistantOpensModbusWorkbenchAndFreezesUserSelectedConnection() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let (devices,backend) = try appUSBFixture()
        let center = ToolboxCenter(environment:environment, usbDevices:devices)
        let picker = center.usbDevices
        await picker.refresh().value
        picker.select(102)
        var setup = ToolboxConnectionSetup()
        setup.serial.connection = .usb
        setup.serial.protocolType = .modbus
        setup.serial.modbusFraming = .ascii
        let request = try picker.request(settings:setup.usbSettings())
        setup.usbRequest = request
        center.connect(.serialAssistant,setup:setup)
        do {
            let deadline = ContinuousClock.now.advanced(by:.seconds(5))
            while center.connecting.contains(.serialAssistant), ContinuousClock.now < deadline {
                try await Task.sleep(for:.milliseconds(10))
            }
            let connection = try #require(center.connections[.serialAssistant], "\(center.failures[.serialAssistant] ?? "No connection")")
            let workbench = try #require(connection.modbusModel)
            #expect(connection.serialModel == nil)
            #expect(await backend.selectedServiceID == 102)
            #expect(await backend.channel.controls == [0, 0x1e, 3, 7])
            workbench.draft = .init(kind:.writeSingleRegister,unitText:"7",addressText:"40010",valuesText:"4660",readBack:false)
            await workbench.refreshPreview()
            #expect(workbench.requestPreview == Data(":070600091234A4\r\n".utf8))
            await workbench.execute(workbench.draft)
            #expect(workbench.result?.writeEchoVerified == true)
            let conversation = try await center.assistant(for:connection), run = UUID()
            try await environment.runStore.saveRun(.init(id:run,conversationID:conversation,state:"executing",goal:"Synthetic Modbus",startedAt:Date()))
            let names = try await center.freeze(runID:run,conversationID:conversation)
            #expect(names == ["toolbox.capture.read","toolbox.modbus.read","toolbox.modbus.write","toolbox.modbus.build","toolbox.modbus.decode"])
            let registry = ToolRunnerRegistry()
            NativeToolboxTools.register(in:registry,enabledNames:names,resolve:{ try await center.resolve($0) })
            let read = try #require(registry.runner(named:"toolbox.modbus.read"))
            let context = ToolContext(runID:run,allowedToolNames:names,cancellation:CancellationToken(),conversationID:conversation,frozenEffectiveCatalogNames:names)
            let arguments = Data(#"{"unit":7,"address":9,"function":3,"quantity":1}"#.utf8)
            let reply = try await read.execute(argumentsJSON:arguments,context:context)
            #expect(reply.summary.contains(#""registerValues":"4660""#))
            #expect(await backend.channel.writes == [Data(":070600091234A4\r\n".utf8),Data(":070300090001EC\r\n".utf8)])
            await center.disconnect(.serialAssistant)
            #expect(throws: ToolboxUSBFailure.changedDevice) { try request.validate() }
            await #expect(throws:ToolboxError.staleSession) { try await read.execute(argumentsJSON:arguments,context:context) }
            await center.disposeAssistantsNow(for:.serialAssistant).value
        } catch {
            await center.disconnect(.serialAssistant)
            await center.disposeAssistantsNow(for:.serialAssistant).value
            throw error
        }
    }

    @Test func actualUSBSessionUsesSelectedDescriptorBoundedReceiveRedactionLeaseAndClose() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let (devices, backend) = try appUSBFixture(); await devices.refresh().value; devices.select(102)
        var setup = ToolboxConnectionSetup()
        setup.serial.connection = .usb; setup.username = "fixture-secret"
        setup.usbRequest = try devices.request(settings: setup.usbSettings())
        let connection = try await ToolboxConnection.open(tool: .serialAssistant, setup: setup,
            environment: environment, workbenchModels: false, usbDevices: devices)
        let captureID = connection.lease.sessionID, ownerID = connection.id
        func removeFixtureCapture() async throws {
            try await environment.database.writer { db in
                try db.execute(sql: "DELETE FROM toolbox_captures WHERE capture_id=? AND owner_id=?", arguments: [captureID.uuidString, ownerID.uuidString])
                try db.execute(sql: "DELETE FROM toolbox_capture_index WHERE capture_id=? AND owner_id=?", arguments: [captureID.uuidString, ownerID.uuidString])
            }
        }
        do {
            let session = try #require(connection.serial)
            #expect(session.endpoint.transport == .usb && session.endpoint.usbVendorID == 0x10c4 && session.endpoint.usbProductID == 0xea60)
            try await session.send(Data([1, 2, 3]), expected: connection.lease)
            let bytes = try await session.receive(expected: connection.lease) // Fails if left at the old 256KiB session default.
            #expect(bytes == Data("fixture-secret".utf8))
            let capture = await connection.journal.snapshot()
            #expect(capture.records.contains { $0.direction == .sent && $0.bytes == Data([1, 2, 3]) })
            #expect(capture.records.contains { $0.direction == .received && $0.redacted })
            await #expect(throws: ToolboxError.staleSession) {
                try await session.send(Data([9]), expected: SessionLease(ownerID: UUID()))
            }
            await connection.close()
            #expect(await backend.channel.closed)
            await #expect(throws: ToolboxError.staleSession) { try await session.send(Data([4]), expected: connection.lease) }
        } catch {
            await connection.close(); try? await removeFixtureCapture(); throw error
        }
        try await removeFixtureCapture()
    }
}
#endif

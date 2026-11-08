import Foundation
import Testing
import CoreBluetooth
@testable import FloeExecution
import FloeToolboxHost

@Suite("Bluetooth serial automatic channel contracts", .serialized)
@MainActor struct BluetoothSerialAutoConnectionTests {
    private let peripheral = UUID(uuidString: "702C890D-B772-4403-8972-3EDFCDB5B38D")!
    private func nus() -> BluetoothSerialGATTService {
        .init(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", characteristics: [
            .init(uuid: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E", canWrite: true, canNotify: false),
            .init(uuid: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", canWrite: false, canNotify: true)])
    }
    private func microchip() -> BluetoothSerialGATTService {
        .init(uuid: "49535343-FE7D-4AE5-8FA9-9FAFD205E455", characteristics: [
            .init(uuid: "49535343-8841-43F4-A8D4-ECBE34729BB3", canWrite: true, canNotify: false),
            .init(uuid: "49535343-1E4D-4BD9-BA61-23C647249616", canWrite: true, canNotify: true),
            .init(uuid: "49535343-4C8A-39B3-2F49-511CFF073B7E", canWrite: true, canNotify: true)])
    }
    @Test func exactProfilesUseDocumentedDataDirectionsAndNeverTheControlPoint() throws {
        let channels = try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [nus(), microchip()])
        #expect(channels.count == 2)
        let n = try #require(channels.first { $0.recognition == .nordicUART })
        let m = try #require(channels.first { $0.recognition == .microchipUART })
        #expect(n.endpoint.writeCharacteristicUUID.hasPrefix("6E400002"))
        #expect(n.endpoint.notifyCharacteristicUUID?.hasPrefix("6E400003") == true)
        #expect(m.endpoint.writeCharacteristicUUID == "49535343-8841-43F4-A8D4-ECBE34729BB3")
        #expect(m.endpoint.notifyCharacteristicUUID == "49535343-1E4D-4BD9-BA61-23C647249616")
        var wrong = nus(); wrong.characteristics[0].canWrite = false
        #expect(try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [wrong]).isEmpty)
        #expect(BluetoothSerialDiscovery.canonicalUUID("ffe0") == "0000FFE0-0000-1000-8000-00805F9B34FB")
    }
    @Test func ambiguousProfilesAreStableAcrossEnumerationOrderAndRequireAChoice() throws {
        let a = try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [nus(), microchip()])
        let b = try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [microchip(), nus()])
        #expect(a == b)
        #expect(throws: BluetoothSerialError.channelSelectionRequired(a)) {
            try BluetoothSerialDiscovery.automaticEndpoint(from: a)
        }
    }
    @Test func unknownWriteNotifyIsNotAutomaticallyCalledUARTAndStandardControlServicesAreExcluded() throws {
        let unknown = BluetoothSerialGATTService(uuid: "11111111-2222-4333-8444-555555555555", characteristics: [
            .init(uuid: "11111112-2222-4333-8444-555555555555", canWrite: true, canNotify: true)])
        let standard = BluetoothSerialGATTService(uuid: "1812", characteristics: unknown.characteristics)
        let dfu = BluetoothSerialGATTService(uuid: "FE59", characteristics: unknown.characteristics)
        let channels = try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [unknown, standard, dfu])
        #expect(channels.count == 1 && channels[0].recognition == .unverified)
        #expect(throws: BluetoothSerialError.channelSelectionRequired(channels)) {
            try BluetoothSerialDiscovery.automaticEndpoint(from: channels)
        }
        #expect(throws: BluetoothSerialError.noSerialChannel) {
            try BluetoothSerialDiscovery.automaticEndpoint(from: [])
        }
    }
    @Test func duplicateAttributeInstancesAndDiscoveryBudgetsFailExplicitly() throws {
        let duplicate = BluetoothSerialGATTService(uuid: "FFE0", characteristics: [
            .init(uuid: "FFE1", canWrite: true, canNotify: false),
            .init(uuid: "0000FFE1-0000-1000-8000-00805F9B34FB", canWrite: false, canNotify: true)])
        #expect(throws: BluetoothSerialError.ambiguousAttributes) {
            try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [duplicate])
        }
        #expect(throws: BluetoothSerialError.discoveryLimit) {
            try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: Array(repeating: nus(), count: 65))
        }
        let many = BluetoothSerialGATTService(uuid: "11111111-2222-4333-8444-555555555555", characteristics: (0..<6).map {
            .init(uuid: String(format: "112233%02X-2222-4333-8444-555555555555", $0), canWrite: true, canNotify: true)
        })
        #expect(throws: BluetoothSerialError.discoveryLimit) {
            try BluetoothSerialDiscovery.channels(peripheralID: peripheral, services: [many])
        }
    }
    @Test func automaticBridgeReturnsActualEndpointAndSendsOnlyUserPayload() async throws {
        let service = RecordingBLE(services: [nus()]); let run = UUID()
        let opened = try await ToolboxBluetoothBridge.openResolved(service: service, runID: run, peripheralID: peripheral)
        #expect(service.events == ["discover", "open"])
        #expect(service.payloads.isEmpty)
        #expect(opened.endpoint == service.openedEndpoint)
        #expect(service.runIDs == [run, run])
        try await opened.connection.send(Data("hello".utf8))
        #expect(service.payloads == [Data("hello".utf8)])
        #expect(try await opened.connection.receive(maximumBytes: 8) == Data("rx".utf8))
        await opened.connection.close()
        #expect(service.closedOwners == [run])
    }
    @Test func selectedChannelAuthenticationErrorReachesTheOriginalHostWithoutProbeWrites() async throws {
        let service = RecordingBLE(services: [nus()])
        service.exchangeError = .authenticationRequired
        let failures = BLEFailureRecorder()
        let opened = try await ToolboxBluetoothBridge.openResolved(service: service, runID: UUID(), peripheralID: peripheral,
            onFailure: { error in await failures.record(error) })
        await #expect(throws: BluetoothSerialError.authenticationRequired) {
            try await opened.connection.send(Data("user request".utf8))
        }
        await service.untilClosed()
        #expect(await failures.errors == [.authenticationRequired])
        #expect(service.payloads.isEmpty && service.closedOwners.count == 1)
    }
    @Test func explicitLegacyEndpointBypassesDiscoveryAndStillUsesTheOriginalAdapter() async throws {
        let data = Data("{\"peripheralID\":\"\(peripheral)\",\"serviceUUID\":\"FFE0\",\"writeCharacteristicUUID\":\"FFE1\"}".utf8)
        let endpoint = try JSONDecoder().decode(BluetoothSerialEndpoint.self, from: data)
        try endpoint.validate(); #expect(endpoint.notifyCharacteristicUUID == nil)
        let service = RecordingBLE(services: [])
        let connection = try await ToolboxBluetoothBridge.open(service: service, runID: UUID(), endpoint: endpoint)
        #expect(service.events == ["open"] && service.openedEndpoint == endpoint && service.payloads.isEmpty)
        await connection.close()
    }
    @Test func choicesAndForeignEndpointsNeverOpenOrWrite() async throws {
        let service = RecordingBLE(services: [nus(), microchip()])
        await #expect(throws: BluetoothSerialError.self) {
            _ = try await BluetoothSerialConnector.open(service: service, runID: UUID(), peripheralID: peripheral)
        }
        #expect(service.events == ["discover"] && service.payloads.isEmpty)
        let foreign = BluetoothSerialEndpoint(peripheralID: UUID(), serviceUUID: "FFE0", writeCharacteristicUUID: "FFE1")
        await #expect(throws: BluetoothSerialError.peripheralMismatch) {
            _ = try await BluetoothSerialConnector.open(service: service, runID: UUID(), peripheralID: peripheral, endpoint: foreign)
        }
        #expect(service.events == ["discover"])
    }
    @Test func nativeReadinessGateRequiresSuccessfulSubscriptionAndRejectsLateCallbacksAfterCancellation() throws {
        var gate = BluetoothSerialOpenReadiness()
        #expect(gate.phase == .discovering)
        try gate.discovered(requiresNotification: true)
        #expect(gate.phase == .awaitingNotification)
        #expect(throws: BluetoothSerialError.notificationNotReady) { try gate.subscribed(isNotifying: false, error: nil) }
        #expect(gate.phase == .awaitingNotification)
        #expect(throws: BluetoothSerialError.authenticationRequired) {
            try gate.subscribed(isNotifying: false, error: NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientAuthentication.rawValue))
        }
        #expect(gate.phase == .awaitingNotification)
        try gate.subscribed(isNotifying: true, error: nil)
        #expect(gate.phase == .ready)
        gate.cancel()
        #expect(throws: CancellationError.self) { try gate.subscribed(isNotifying: true, error: nil) }
        #expect(gate.phase == .cancelled)
        var writeOnly = BluetoothSerialOpenReadiness(); try writeOnly.discovered(requiresNotification: false)
        #expect(writeOnly.phase == .ready)
    }
    @Test func subscriptionWaitAndAuthenticationFailureCannotProduceAReadyConnection() async throws {
        let service = RecordingBLE(services: [nus()]); service.waitForSubscription = true
        var ready = false
        let operation = Task { @MainActor in
            _ = try await BluetoothSerialConnector.open(service: service, runID: UUID(), peripheralID: peripheral)
            ready = true
        }
        await service.untilOpenWaits()
        #expect(!ready && service.payloads.isEmpty)
        service.completeSubscription(.failure(BluetoothSerialError.from(NSError(domain: CBATTErrorDomain,
            code: CBATTError.insufficientAuthentication.rawValue))))
        await #expect(throws: BluetoothSerialError.authenticationRequired) { try await operation.value }
        #expect(!ready && service.payloads.isEmpty)
    }
    @Test func cancellingDuringDiscoveryDoesNotOpenAndLateOpenIsClosedByItsCapturedOwner() async throws {
        let first = RecordingBLE(services: [nus()]); first.waitForDiscovery = true
        let operation = Task { try await BluetoothSerialConnector.open(service: first, runID: UUID(), peripheralID: peripheral) }
        await first.untilDiscoveryWaits(); operation.cancel(); first.completeDiscovery()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(first.events == ["discover"] && first.payloads.isEmpty)

        let second = RecordingBLE(services: [nus()]); second.waitForSubscription = true
        let run = UUID()
        let late = Task { try await BluetoothSerialConnector.open(service: second, runID: run, peripheralID: peripheral) }
        await second.untilOpenWaits(); late.cancel(); second.completeSubscription(.success(second.sessionID))
        await #expect(throws: CancellationError.self) { _ = try await late.value }
        #expect(second.closedOwners == [run] && second.payloads.isEmpty)
    }
    @Test func errorsDistinguishAuthenticationAccessAndRadioAndInvalidUUIDsDoNotInitializeBluetooth() async throws {
        for code in [CBATTError.insufficientAuthentication, .insufficientEncryption, .insufficientEncryptionKeySize] {
            #expect(BluetoothSerialError.from(NSError(domain: CBATTErrorDomain, code: code.rawValue)) == .authenticationRequired)
        }
        #expect(BluetoothSerialError.from(NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientAuthorization.rawValue)) == .accessoryAccessDenied)
        #expect(BluetoothSerialError.permissionDenied != .authenticationRequired)
        #expect(BluetoothSerialError.poweredOff != .unsupported)
        let service = CoreBluetoothSerialService() // central is lazy; only invalid input is exercised.
        await #expect(throws: BluetoothSerialError.connectionFailed("Use a 4-digit, 8-digit or standard 128-bit GATT UUID")) {
            _ = try await service.open(runID: UUID(), endpoint: .init(peripheralID: peripheral,
                serviceUUID: "NOT-A-UUID", writeCharacteristicUUID: "FFE1"), timeout: 1)
        }
    }
}

@MainActor private final class RecordingBLE: BluetoothSerialServicing {
    let services: [BluetoothSerialGATTService]
    let sessionID = UUID()
    var events: [String] = []
    var runIDs: [UUID] = []
    var payloads: [Data] = []
    var closedOwners: [UUID] = []
    var openedEndpoint: BluetoothSerialEndpoint?
    var exchangeError: BluetoothSerialError?
    var waitForSubscription = false, waitForDiscovery = false
    private var openContinuation: CheckedContinuation<UUID, Error>?
    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    private var openStarted: CheckedContinuation<Void, Never>?
    private var discoveryStarted: CheckedContinuation<Void, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    init(services: [BluetoothSerialGATTService]) { self.services = services }
    func scan(duration: TimeInterval) async throws -> [BluetoothSerialPeripheral] { throw BluetoothSerialError.unsupported }
    func discoverChannels(runID: UUID, peripheralID: UUID, timeout: TimeInterval) async throws -> [BluetoothSerialChannel] {
        events.append("discover"); runIDs.append(runID)
        if waitForDiscovery {
            await withCheckedContinuation { continuation in
                discoveryContinuation = continuation; discoveryStarted?.resume(); discoveryStarted = nil
            }
        }
        return try BluetoothSerialDiscovery.channels(peripheralID: peripheralID, services: services)
    }
    func open(runID: UUID, endpoint: BluetoothSerialEndpoint, timeout: TimeInterval) async throws -> UUID {
        events.append("open"); runIDs.append(runID); openedEndpoint = endpoint
        if waitForSubscription {
            return try await withCheckedThrowingContinuation { continuation in
                openContinuation = continuation; openStarted?.resume(); openStarted = nil
            }
        }
        return sessionID
    }
    func untilOpenWaits() async {
        if openContinuation != nil { return }
        await withCheckedContinuation { openStarted = $0 }
    }
    func untilDiscoveryWaits() async {
        if discoveryContinuation != nil { return }
        await withCheckedContinuation { discoveryStarted = $0 }
    }
    func completeSubscription(_ result: Result<UUID, Error>) { openContinuation?.resume(with: result); openContinuation = nil }
    func completeDiscovery() { discoveryContinuation?.resume(); discoveryContinuation = nil }
    func exchange(runID: UUID, sessionID: UUID, data: Data?, wait: TimeInterval, maxBytes: Int) async throws -> Data {
        #expect(sessionID == self.sessionID && runIDs.contains(runID))
        if let exchangeError { throw exchangeError }
        if let data { payloads.append(data); return Data() }
        return Data("rx".utf8)
    }
    func untilClosed() async {
        if !closedOwners.isEmpty { return }
        await withCheckedContinuation { closeWaiter = $0 }
    }
    func close(runID: UUID, sessionID: UUID) async {
        #expect(sessionID == self.sessionID); closedOwners.append(runID); closeWaiter?.resume(); closeWaiter = nil
    }
}

private actor BLEFailureRecorder {
    var errors: [BluetoothSerialError] = []
    func record(_ error: Error) { if let error = error as? BluetoothSerialError { errors.append(error) } }
}

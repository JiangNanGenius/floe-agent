import Foundation
@preconcurrency import CoreBluetooth
import FloeCore

public struct BluetoothSerialPeripheral: Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String?
    public var rssi: Int
}

public struct BluetoothSerialEndpoint: Sendable, Codable, Equatable {
    public var peripheralID: UUID
    public var serviceUUID: String
    public var writeCharacteristicUUID: String
    public var notifyCharacteristicUUID: String?

    public init(
        peripheralID: UUID,
        serviceUUID: String,
        writeCharacteristicUUID: String,
        notifyCharacteristicUUID: String? = nil
    ) {
        self.peripheralID = peripheralID
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.notifyCharacteristicUUID = notifyCharacteristicUUID
    }

    public func validate() throws {
        let values = [serviceUUID, writeCharacteristicUUID] + (notifyCharacteristicUUID.map { [$0] } ?? [])
        guard values.allSatisfy(Self.isValidGATTUUID) else {
            throw BluetoothSerialError.connectionFailed("Use a 4-digit, 8-digit or standard 128-bit GATT UUID")
        }
    }

    private static func isValidGATTUUID(_ value: String) -> Bool {
        if value.utf8.count == 4 || value.utf8.count == 8 {
            return value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        }
        return value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

}

@MainActor
public protocol BluetoothSerialServicing: Sendable {
    func scan(duration: TimeInterval) async throws -> [BluetoothSerialPeripheral]
    func discoverChannels(runID: UUID, peripheralID: UUID, timeout: TimeInterval) async throws -> [BluetoothSerialChannel]
    func open(runID: UUID, endpoint: BluetoothSerialEndpoint, timeout: TimeInterval) async throws -> UUID
    func exchange(runID: UUID, sessionID: UUID, data: Data?, wait: TimeInterval, maxBytes: Int) async throws -> Data
    func close(runID: UUID, sessionID: UUID) async
}

public extension BluetoothSerialServicing {
    // Existing adapters remain source compatible; unsupported discovery never
    // invents an endpoint or silently falls back to a guessed characteristic.
    func discoverChannels(runID: UUID, peripheralID: UUID, timeout: TimeInterval) async throws -> [BluetoothSerialChannel] {
        throw BluetoothSerialError.noSerialChannel
    }
}

public enum BluetoothSerialError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(String), peripheralNotFound, serviceNotFound, writeCharacteristicNotFound
    case connectionFailed(String), notifyCharacteristicNotFound, notificationNotReady
    case permissionDenied, poweredOff, unsupported, notReady, timedOut, connectionBusy
    case authenticationRequired, accessoryAccessDenied, disconnected
    case noSerialChannel, channelSelectionRequired([BluetoothSerialChannel])
    case ambiguousAttributes, discoveryLimit, peripheralMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Bluetooth is unavailable: \(reason)"
        case .peripheralNotFound: "The BLE peripheral was not found nearby."
        case .serviceNotFound: "The selected BLE service was not found."
        case .writeCharacteristicNotFound: "The selected characteristic is missing or does not support writing."
        case .connectionFailed(let reason): "BLE connection failed: \(reason)"
        case .notifyCharacteristicNotFound: "The selected receive characteristic is missing or does not support notifications."
        case .notificationNotReady: "The device did not enable notifications for the selected channel."
        case .permissionDenied: "Bluetooth permission was not granted."
        case .poweredOff: "Bluetooth is turned off."
        case .unsupported: "Bluetooth Low Energy is unsupported on this device."
        case .notReady: "Bluetooth did not become ready."
        case .timedOut: "The Bluetooth operation timed out."
        case .connectionBusy: "This peripheral already has an active connection or operation."
        case .authenticationRequired: "The selected channel requires authentication. Complete any system prompt, then reconnect; no data was automatically sent."
        case .accessoryAccessDenied: "The accessory denied access to the selected channel."
        case .disconnected: "The Bluetooth connection ended."
        case .noSerialChannel: "No supported BLE serial channel was found. Classic Bluetooth SPP is not exposed by CoreBluetooth."
        case .channelSelectionRequired: "Choose a discovered data channel before connecting."
        case .ambiguousAttributes: "Duplicate GATT attribute UUIDs cannot be addressed unambiguously by this serial adapter."
        case .discoveryLimit: "The device's GATT layout exceeds the bounded serial discovery limit."
        case .peripheralMismatch: "The selected channel belongs to another peripheral."
        }
    }

    /// Preserve ATT authentication failures instead of reporting permission or
    /// a successful connection. CoreBluetooth owns any system security prompt.
    public static func from(_ error: Error) -> BluetoothSerialError {
        if let error = error as? Self { return error }
        let value = error as NSError
        if value.domain == CBATTErrorDomain {
            switch value.code {
            case CBATTError.insufficientAuthentication.rawValue, CBATTError.insufficientEncryption.rawValue,
                 CBATTError.insufficientEncryptionKeySize.rawValue: return .authenticationRequired
            case CBATTError.insufficientAuthorization.rawValue, CBATTError.readNotPermitted.rawValue,
                 CBATTError.writeNotPermitted.rawValue: return .accessoryAccessDenied
            default: break
            }
        }
        if value.domain == CBErrorDomain, value.code == CBError.peerRemovedPairingInformation.rawValue {
            return .authenticationRequired
        }
        return .connectionFailed(value.localizedDescription)
    }
}

/// Foreground BLE GATT transport. Discovery only inspects metadata; only the
/// selected channel is subscribed, and writes require an actual caller payload.
@MainActor
public final class CoreBluetoothSerialService: NSObject, BluetoothSerialServicing,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private struct Session {
        let runID: UUID
        let peripheral: CBPeripheral
        let write: CBCharacteristic
        let notify: CBCharacteristic?
        var received: Data
        var failure: BluetoothSerialError?
    }
    private final class Request {
        let id: UUID
        let runID: UUID
        let peripheral: CBPeripheral
        let endpoint: BluetoothSerialEndpoint?
        let openGate: BLEContinuationGate<UUID>?
        let discoveryGate: BLEContinuationGate<[BluetoothSerialChannel]>?
        var pendingServices = Set<ObjectIdentifier>()
        var snapshots: [BluetoothSerialGATTService] = []
        var discoveredChannels: [BluetoothSerialChannel]?
        var write: CBCharacteristic?
        var notify: CBCharacteristic?
        var received = Data()
        var readiness = BluetoothSerialOpenReadiness()
        var timeoutTask: Task<Void, Never>?
        init(id: UUID, runID: UUID, peripheral: CBPeripheral, endpoint: BluetoothSerialEndpoint?,
             openGate: BLEContinuationGate<UUID>? = nil,
             discoveryGate: BLEContinuationGate<[BluetoothSerialChannel]>? = nil) {
            self.id = id; self.runID = runID; self.peripheral = peripheral; self.endpoint = endpoint
            self.openGate = openGate; self.discoveryGate = discoveryGate
        }
        func fail(_ error: Error) { _ = openGate?.resume(throwing: error); _ = discoveryGate?.resume(throwing: error) }
    }
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var powerWaiters: [UUID: BLEContinuationGate<Void>] = [:]
    private var discovered: [UUID: (CBPeripheral, Int)] = [:]
    private var requests: [UUID: Request] = [:]
    private var disconnecting = Set<UUID>()
    private var sessions: [UUID: Session] = [:]
    private var writeWaiters: [UUID: BLEContinuationGate<Void>] = [:]
    private var scanID: UUID?

    public override init() { super.init() } // Authorization starts only on explicit scan/open.

    public func scan(duration: TimeInterval = 5) async throws -> [BluetoothSerialPeripheral] {
        guard duration.isFinite else { throw BluetoothSerialError.connectionFailed("invalid scan duration") }
        try await waitUntilPoweredOn(); try Task.checkCancellation()
        guard scanID == nil else { throw BluetoothSerialError.connectionBusy }
        let id = UUID(); scanID = id
        discovered.removeAll(keepingCapacity: true)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        defer { if scanID == id { central.stopScan(); scanID = nil } }
        try await Task.sleep(for: .seconds(min(max(duration, 1), 15)))
        try await waitUntilPoweredOn(); try Task.checkCancellation()
        return discovered.values.map { BluetoothSerialPeripheral(id: $0.0.identifier, name: $0.0.name, rssi: $0.1) }
            .sorted { ($0.name ?? $0.id.uuidString) < ($1.name ?? $1.id.uuidString) }
    }

    public func discoverChannels(runID: UUID, peripheralID: UUID, timeout: TimeInterval = 15) async throws -> [BluetoothSerialChannel] {
        let peripheral = try await peripheralForOperation(peripheralID, timeout: timeout)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(id: id, runID: runID, peripheral: peripheral, endpoint: nil,
                    discoveryGate: BLEContinuationGate(continuation))
                begin(request, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(peripheralID, id: id, error: CancellationError()) }
        }
    }

    public func open(runID: UUID, endpoint: BluetoothSerialEndpoint, timeout: TimeInterval = 15) async throws -> UUID {
        // CBUUID(string:) can raise an Objective-C exception for invalid input.
        try endpoint.validate()
        let peripheral = try await peripheralForOperation(endpoint.peripheralID, timeout: timeout)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(id: id, runID: runID, peripheral: peripheral, endpoint: endpoint,
                    openGate: BLEContinuationGate(continuation))
                begin(request, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(endpoint.peripheralID, id: id, error: CancellationError()) }
        }
    }

    private func peripheralForOperation(_ id: UUID, timeout: TimeInterval) async throws -> CBPeripheral {
        guard timeout.isFinite else { throw BluetoothSerialError.connectionFailed("invalid timeout") }
        try await waitUntilPoweredOn(); try Task.checkCancellation()
        var peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        if peripheral == nil {
            _ = try await scan(duration: min(max(timeout, 1), 5)); try Task.checkCancellation()
            peripheral = discovered[id]?.0
        }
        guard let peripheral else { throw BluetoothSerialError.peripheralNotFound }
        guard requests[id] == nil, !disconnecting.contains(id),
              !sessions.values.contains(where: { $0.peripheral.identifier == id }) else { throw BluetoothSerialError.connectionBusy }
        return peripheral
    }

    private func begin(_ request: Request, timeout: TimeInterval) {
        let peripheral = request.peripheral
        guard requests[peripheral.identifier] == nil, !disconnecting.contains(peripheral.identifier),
              !sessions.values.contains(where: { $0.peripheral.identifier == peripheral.identifier }) else {
            request.fail(BluetoothSerialError.connectionBusy); return
        }
        requests[peripheral.identifier] = request
        peripheral.delegate = self
        central.connect(peripheral)
        let id = request.id; let peripheralID = peripheral.identifier
        request.timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(min(max(timeout, 1), 30))) } catch { return }
            self?.cancelRequest(peripheralID, id: id, error: BluetoothSerialError.timedOut)
        }
    }

    public func exchange(runID: UUID, sessionID: UUID, data: Data?, wait: TimeInterval, maxBytes: Int) async throws -> Data {
        guard wait.isFinite else { throw BluetoothSerialError.connectionFailed("invalid wait") }
        guard let session = sessions[sessionID], session.runID == runID else { throw FloeError.notFound("Temporary BLE serial session") }
        if let failure = session.failure { throw failure }
        try Task.checkCancellation()
        if let data, !data.isEmpty {
            if session.write.properties.contains(.write) {
                let peripheralID = session.peripheral.identifier
                guard writeWaiters[peripheralID] == nil else { throw BluetoothSerialError.connectionBusy }
                let gateID = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let gate = BLEContinuationGate(continuation, id: gateID)
                        writeWaiters[peripheralID] = gate
                        session.peripheral.writeValue(data, for: session.write, type: .withResponse)
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(10))
                            guard let self, self.writeWaiters[peripheralID] === gate else { return }
                            self.writeWaiters[peripheralID] = nil; _ = gate.resume(throwing: BluetoothSerialError.timedOut)
                        }
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        guard let self, let gate = self.writeWaiters[peripheralID], gate.id == gateID else { return }
                        self.writeWaiters[peripheralID] = nil; _ = gate.resume(throwing: CancellationError())
                    }
                }
            } else if session.write.properties.contains(.writeWithoutResponse) {
                session.peripheral.writeValue(data, for: session.write, type: .withoutResponse)
            } else { throw BluetoothSerialError.writeCharacteristicNotFound }
        }
        try await Task.sleep(for: .seconds(min(max(wait, 0.05), 30)))
        guard var latest = sessions[sessionID], latest.runID == runID else { throw BluetoothSerialError.disconnected }
        if let failure = latest.failure { throw failure }
        let count = min(max(maxBytes, 1), min(latest.received.count, 262_144))
        let result = latest.received.prefix(count); latest.received.removeFirst(count); sessions[sessionID] = latest
        return Data(result)
    }

    public func close(runID: UUID, sessionID: UUID) async {
        guard let session = sessions[sessionID], session.runID == runID else { return }
        sessions[sessionID] = nil
        if let gate = writeWaiters.removeValue(forKey: session.peripheral.identifier) { _ = gate.resume(throwing: BluetoothSerialError.disconnected) }
        disconnect(session.peripheral)
        await SessionExpiryScheduler.shared.cancel(id: sessionID)
    }

    private func waitUntilPoweredOn() async throws {
        try Task.checkCancellation()
        switch CBManager.authorization {
        case .denied, .restricted: throw BluetoothSerialError.permissionDenied
        case .allowedAlways, .notDetermined: break
        @unknown default: throw BluetoothSerialError.notReady
        }
        switch central.state {
        case .poweredOn: return
        case .unsupported: throw BluetoothSerialError.unsupported
        case .unauthorized: throw BluetoothSerialError.permissionDenied
        case .poweredOff: throw BluetoothSerialError.poweredOff
        case .resetting, .unknown:
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let gate = BLEContinuationGate(continuation); powerWaiters[id] = gate
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard let self, self.powerWaiters.removeValue(forKey: id) != nil else { return }
                        _ = gate.resume(throwing: BluetoothSerialError.notReady)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let gate = self?.powerWaiters.removeValue(forKey: id) else { return }
                    _ = gate.resume(throwing: CancellationError())
                }
            }
        @unknown default: throw BluetoothSerialError.notReady
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        let waiters = Array(powerWaiters.values); powerWaiters.removeAll()
        if central.state == .poweredOn { waiters.forEach { _ = $0.resume(returning: ()) }; return }
        let error: BluetoothSerialError = central.state == .unauthorized ? .permissionDenied :
            central.state == .poweredOff ? .poweredOff : central.state == .unsupported ? .unsupported : .notReady
        waiters.forEach { _ = $0.resume(throwing: error) }
        for request in requests.values { request.timeoutTask?.cancel(); request.readiness.cancel(); request.fail(error) }
        requests.removeAll(); disconnecting.removeAll()
        let expired = Array(sessions.keys); sessions.removeAll()
        Task { for id in expired { await SessionExpiryScheduler.shared.cancel(id: id) } }
        writeWaiters.values.forEach { _ = $0.resume(throwing: error) }; writeWaiters.removeAll()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanID != nil, discovered.count < 256 || discovered[peripheral.identifier] != nil else { return }
        discovered[peripheral.identifier] = (peripheral, RSSI.intValue)
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let request = requests[peripheral.identifier] else { disconnect(peripheral); return }
        peripheral.discoverServices(request.endpoint.map { [CBUUID(string: $0.serviceUUID)] })
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnecting.remove(peripheral.identifier)
        fail(peripheral.identifier, error: BluetoothSerialError.from(error ?? BluetoothSerialError.disconnected), disconnect: false)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnecting.remove(peripheral.identifier)
        if let request = requests[peripheral.identifier], let channels = request.discoveredChannels {
            requests[peripheral.identifier] = nil; request.timeoutTask?.cancel()
            _ = request.discoveryGate?.resume(returning: channels)
        } else { fail(peripheral.identifier, error: BluetoothSerialError.from(error ?? BluetoothSerialError.disconnected), disconnect: false) }
        for (id, session) in sessions where session.peripheral.identifier == peripheral.identifier {
            sessions[id] = nil
            Task { await SessionExpiryScheduler.shared.cancel(id: id) }
        }
        if let waiter = writeWaiters.removeValue(forKey: peripheral.identifier) {
            _ = waiter.resume(throwing: BluetoothSerialError.from(error ?? BluetoothSerialError.disconnected))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let request = requests[peripheral.identifier] else { return }
        if let error { fail(peripheral.identifier, error: BluetoothSerialError.from(error)); return }
        var services = peripheral.services ?? []
        if let endpoint = request.endpoint { services = services.filter { $0.uuid == CBUUID(string: endpoint.serviceUUID) } }
        guard !services.isEmpty else { fail(peripheral.identifier, error: BluetoothSerialError.serviceNotFound); return }
        guard services.count <= 64 else { fail(peripheral.identifier, error: BluetoothSerialError.discoveryLimit); return }
        if request.endpoint != nil, services.count != 1 { fail(peripheral.identifier, error: BluetoothSerialError.ambiguousAttributes); return }
        request.pendingServices = Set(services.map(ObjectIdentifier.init))
        for service in services {
            let ids = request.endpoint.map { [$0.writeCharacteristicUUID, $0.notifyCharacteristicUUID].compactMap { $0 }.map(CBUUID.init(string:)) }
            peripheral.discoverCharacteristics(ids, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let request = requests[peripheral.identifier], request.pendingServices.remove(ObjectIdentifier(service)) != nil else { return }
        if let error { fail(peripheral.identifier, error: BluetoothSerialError.from(error)); return }
        let characteristics = service.characteristics ?? []
        guard characteristics.count <= 128 else { fail(peripheral.identifier, error: BluetoothSerialError.discoveryLimit); return }
        if let endpoint = request.endpoint {
            let writes = characteristics.filter { $0.uuid == CBUUID(string: endpoint.writeCharacteristicUUID) }
            guard writes.count == 1 else { fail(peripheral.identifier, error: writes.isEmpty ? BluetoothSerialError.writeCharacteristicNotFound : .ambiguousAttributes); return }
            let write = writes[0]
            guard write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse) else {
                fail(peripheral.identifier, error: BluetoothSerialError.writeCharacteristicNotFound); return
            }
            request.write = write
            do { try request.readiness.discovered(requiresNotification: endpoint.notifyCharacteristicUUID != nil) }
            catch { fail(peripheral.identifier, error: error); return }
            if let notifyID = endpoint.notifyCharacteristicUUID {
                let matches = characteristics.filter { $0.uuid == CBUUID(string: notifyID) }
                guard matches.count == 1 else { fail(peripheral.identifier, error: matches.isEmpty ? BluetoothSerialError.notifyCharacteristicNotFound : .ambiguousAttributes); return }
                let notify = matches[0]
                guard notify.properties.supportsSerialNotifications else {
                    fail(peripheral.identifier, error: BluetoothSerialError.notifyCharacteristicNotFound); return
                }
                request.notify = notify
                // Only this selected channel can trigger a system authentication
                // prompt. Success waits for didUpdateNotificationState below.
                peripheral.setNotifyValue(true, for: notify)
            } else { completeOpen(request) } // Existing explicit write-only configurations remain valid.
        } else {
            request.snapshots.append(.init(uuid: service.uuid.uuidString, characteristics: characteristics.map {
                .init(uuid: $0.uuid.uuidString,
                      canWrite: $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse),
                      canNotify: $0.properties.supportsSerialNotifications)
            }))
            guard request.pendingServices.isEmpty else { return }
            do {
                request.discoveredChannels = try BluetoothSerialDiscovery.channels(peripheralID: peripheral.identifier, services: request.snapshots)
                // Do not return a live/discovering peripheral to a different
                // owner. Await its actual disconnect before a selected reopen.
                if peripheral.state == .disconnected {
                    requests[peripheral.identifier] = nil; request.timeoutTask?.cancel()
                    _ = request.discoveryGate?.resume(returning: request.discoveredChannels!)
                } else { disconnect(peripheral) }
            } catch { fail(peripheral.identifier, error: error) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let request = requests[peripheral.identifier], request.notify === characteristic else {
            if let error { markFailure(peripheral.identifier, characteristic: characteristic, error: error) }
            else if !characteristic.isNotifying { markFailure(peripheral.identifier, characteristic: characteristic, error: BluetoothSerialError.notificationNotReady) }
            return
        }
        do { try request.readiness.subscribed(isNotifying: characteristic.isNotifying, error: error) }
        catch { fail(peripheral.identifier, error: error); return }
        completeOpen(request)
    }
    private func completeOpen(_ request: Request) {
        guard requests[request.peripheral.identifier] === request, request.readiness.phase == .ready,
              let write = request.write, let gate = request.openGate else { return }
        requests[request.peripheral.identifier] = nil; request.timeoutTask?.cancel()
        let id = UUID()
        sessions[id] = Session(runID: request.runID, peripheral: request.peripheral, write: write,
                               notify: request.notify, received: request.received)
        _ = gate.resume(returning: id)
        Task { [weak self] in
            await SessionExpiryScheduler.shared.schedule(id: id, after: 30 * 60) { [weak self] in await self?.expire(sessionID: id) }
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard sessions.values.contains(where: { $0.peripheral.identifier == peripheral.identifier && $0.write === characteristic }),
              let waiter = writeWaiters.removeValue(forKey: peripheral.identifier) else { return }
        if let error { _ = waiter.resume(throwing: BluetoothSerialError.from(error)) }
        else { _ = waiter.resume(returning: ()) }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { markFailure(peripheral.identifier, characteristic: characteristic, error: error); return }
        guard let value = characteristic.value else { return }
        if let request = requests[peripheral.identifier], request.notify === characteristic {
            guard value.count <= 262_144 - request.received.count else {
                fail(peripheral.identifier, error: BluetoothSerialError.connectionFailed("receive buffer full")); return
            }
            request.received.append(value)
        }
        for (id, var session) in sessions where session.peripheral.identifier == peripheral.identifier && session.notify === characteristic {
            if value.count > 262_144 - session.received.count { session.failure = .connectionFailed("receive buffer full") }
            else { session.received.append(value) }
            sessions[id] = session
        }
    }
    private func markFailure(_ peripheralID: UUID, characteristic: CBCharacteristic, error: Error) {
        for (id, var session) in sessions where session.peripheral.identifier == peripheralID && session.notify === characteristic {
            session.failure = BluetoothSerialError.from(error); sessions[id] = session
        }
    }
    private func cancelRequest(_ peripheralID: UUID, id: UUID, error: Error) {
        guard requests[peripheralID]?.id == id else { return }
        fail(peripheralID, error: error)
    }
    private func fail(_ peripheralID: UUID, error: Error, disconnect shouldDisconnect: Bool = true) {
        guard let request = requests.removeValue(forKey: peripheralID) else { return }
        request.timeoutTask?.cancel(); request.readiness.cancel(); request.fail(error)
        if shouldDisconnect { disconnect(request.peripheral) }
    }
    private func disconnect(_ peripheral: CBPeripheral) {
        guard peripheral.state != .disconnected else { return }
        disconnecting.insert(peripheral.identifier); central.cancelPeripheralConnection(peripheral)
    }
    private func expire(sessionID: UUID) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        if let gate = writeWaiters.removeValue(forKey: session.peripheral.identifier) { _ = gate.resume(throwing: BluetoothSerialError.disconnected) }
        disconnect(session.peripheral)
    }
}

private final class BLEContinuationGate<Value: Sendable>: @unchecked Sendable {
    let id: UUID
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>, id: UUID = UUID()) { self.continuation = continuation; self.id = id }
    @discardableResult func resume(returning value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }; self.continuation = nil
        continuation.resume(returning: value); return true
    }
    @discardableResult func resume(throwing error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }; self.continuation = nil
        continuation.resume(throwing: error); return true
    }
}

private extension CBCharacteristicProperties {
    var supportsSerialNotifications: Bool {
        contains(.notify) || contains(.indicate) || contains(.notifyEncryptionRequired) || contains(.indicateEncryptionRequired)
    }
}

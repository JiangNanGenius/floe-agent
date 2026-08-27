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
}

@MainActor
public protocol BluetoothSerialServicing: Sendable {
    func scan(duration: TimeInterval) async throws -> [BluetoothSerialPeripheral]
    func open(runID: UUID, endpoint: BluetoothSerialEndpoint, timeout: TimeInterval) async throws -> UUID
    func exchange(runID: UUID, sessionID: UUID, data: Data?, wait: TimeInterval, maxBytes: Int) async throws -> Data
    func close(runID: UUID, sessionID: UUID) async
}

public enum BluetoothSerialError: Error, Sendable, LocalizedError {
    case unavailable(String)
    case peripheralNotFound
    case serviceNotFound
    case writeCharacteristicNotFound
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Bluetooth is unavailable: \(reason)"
        case .peripheralNotFound: "The BLE serial peripheral was not found nearby."
        case .serviceNotFound: "The configured BLE GATT service was not found."
        case .writeCharacteristicNotFound: "The configured BLE write characteristic was not found."
        case .connectionFailed(let reason): "BLE serial connection failed: \(reason)"
        }
    }
}

/// Foreground BLE GATT serial transport. iOS does not expose arbitrary
/// classic Bluetooth SPP; compatible accessories publish writable/notifying
/// GATT characteristics instead. Pairing remains owned by the system.
@MainActor
public final class CoreBluetoothSerialService: NSObject, BluetoothSerialServicing,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {

    private struct Session {
        var runID: UUID
        var peripheral: CBPeripheral
        var write: CBCharacteristic
        var notify: CBCharacteristic?
        var received = Data()
    }

    private final class OpenRequest {
        let endpoint: BluetoothSerialEndpoint
        let runID: UUID
        let gate: BLEContinuationGate<UUID>

        init(endpoint: BluetoothSerialEndpoint, runID: UUID, gate: BLEContinuationGate<UUID>) {
            self.endpoint = endpoint
            self.runID = runID
            self.gate = gate
        }
    }

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var powerWaiters: [BLEContinuationGate<Void>] = []
    private var discovered: [UUID: (CBPeripheral, Int)] = [:]
    private var openRequests: [UUID: OpenRequest] = [:]
    private var sessions: [UUID: Session] = [:]
    private var writeWaiters: [UUID: BLEContinuationGate<Void>] = [:]

    public override init() {
        super.init()
        _ = central
    }

    public func scan(duration: TimeInterval = 5) async throws -> [BluetoothSerialPeripheral] {
        try await waitUntilPoweredOn()
        discovered.removeAll(keepingCapacity: true)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        do {
            try await Task.sleep(for: .seconds(min(max(duration, 1), 15)))
        } catch {
            central.stopScan()
            throw error
        }
        central.stopScan()
        return discovered.values.map { peripheral, rssi in
            BluetoothSerialPeripheral(id: peripheral.identifier, name: peripheral.name, rssi: rssi)
        }.sorted { ($0.name ?? $0.id.uuidString) < ($1.name ?? $1.id.uuidString) }
    }

    public func open(
        runID: UUID,
        endpoint: BluetoothSerialEndpoint,
        timeout: TimeInterval = 15
    ) async throws -> UUID {
        try await waitUntilPoweredOn()
        var peripheral = central.retrievePeripherals(withIdentifiers: [endpoint.peripheralID]).first
        if peripheral == nil {
            _ = try await scan(duration: min(timeout, 5))
            peripheral = discovered[endpoint.peripheralID]?.0
        }
        guard let peripheral else { throw BluetoothSerialError.peripheralNotFound }
        guard openRequests[peripheral.identifier] == nil else {
            throw BluetoothSerialError.connectionFailed("a connection attempt is already in progress")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
            let gate = BLEContinuationGate(continuation)
            openRequests[peripheral.identifier] = OpenRequest(endpoint: endpoint, runID: runID, gate: gate)
            peripheral.delegate = self
            central.connect(peripheral)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(min(max(timeout, 1), 30)))
                guard let self, let request = self.openRequests.removeValue(forKey: peripheral.identifier) else { return }
                if request.gate.resume(throwing: BluetoothSerialError.connectionFailed("timed out")) {
                    self.central.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    public func exchange(
        runID: UUID,
        sessionID: UUID,
        data: Data?,
        wait: TimeInterval,
        maxBytes: Int
    ) async throws -> Data {
        guard let session = sessions[sessionID], session.runID == runID else {
            throw FloeError.notFound("Temporary BLE serial session")
        }
        if let data, !data.isEmpty {
            if session.write.properties.contains(.write) {
                guard writeWaiters[session.peripheral.identifier] == nil else {
                    throw BluetoothSerialError.connectionFailed("a write is already in progress")
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let gate = BLEContinuationGate(continuation)
                    writeWaiters[session.peripheral.identifier] = gate
                    session.peripheral.writeValue(data, for: session.write, type: .withResponse)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard let self,
                              let current = self.writeWaiters[session.peripheral.identifier],
                              current === gate else { return }
                        self.writeWaiters.removeValue(forKey: session.peripheral.identifier)
                        _ = gate.resume(throwing: BluetoothSerialError.connectionFailed("write timed out"))
                    }
                }
            } else if session.write.properties.contains(.writeWithoutResponse) {
                session.peripheral.writeValue(data, for: session.write, type: .withoutResponse)
            } else {
                throw BluetoothSerialError.writeCharacteristicNotFound
            }
        }
        try await Task.sleep(for: .seconds(min(max(wait, 0.05), 30)))
        guard var latest = sessions[sessionID] else { return Data() }
        let count = min(max(maxBytes, 1), min(latest.received.count, 262_144))
        let result = latest.received.prefix(count)
        latest.received.removeFirst(count)
        sessions[sessionID] = latest
        return Data(result)
    }

    public func close(runID: UUID, sessionID: UUID) async {
        guard let session = sessions[sessionID], session.runID == runID else { return }
        sessions.removeValue(forKey: sessionID)
        central.cancelPeripheralConnection(session.peripheral)
    }

    private func waitUntilPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unsupported: throw BluetoothSerialError.unavailable("unsupported on this device")
        case .unauthorized: throw BluetoothSerialError.unavailable("permission was not granted")
        case .poweredOff: throw BluetoothSerialError.unavailable("Bluetooth is turned off")
        case .resetting, .unknown:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = BLEContinuationGate(continuation)
                powerWaiters.append(gate)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, self.powerWaiters.contains(where: { $0 === gate }) else { return }
                    self.powerWaiters.removeAll { $0 === gate }
                    _ = gate.resume(throwing: BluetoothSerialError.unavailable("Bluetooth did not become ready"))
                }
            }
        @unknown default:
            throw BluetoothSerialError.unavailable("unknown state")
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        let waiters = powerWaiters
        powerWaiters.removeAll()
        if central.state == .poweredOn {
            waiters.forEach { _ = $0.resume(returning: ()) }
        } else {
            let reason = BluetoothSerialError.unavailable(String(describing: central.state))
            waiters.forEach { _ = $0.resume(throwing: reason) }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discovered[peripheral.identifier] = (peripheral, RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let request = openRequests[peripheral.identifier] else { return }
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: request.endpoint.serviceUUID)])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        failOpen(peripheral.identifier, error: error ?? BluetoothSerialError.connectionFailed("connection rejected"))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failOpen(peripheral.identifier, error: error); return }
        guard let request = openRequests[peripheral.identifier],
              let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: request.endpoint.serviceUUID)
              }) else {
            failOpen(peripheral.identifier, error: BluetoothSerialError.serviceNotFound)
            return
        }
        let ids = [request.endpoint.writeCharacteristicUUID, request.endpoint.notifyCharacteristicUUID]
            .compactMap { $0 }.map(CBUUID.init(string:))
        peripheral.discoverCharacteristics(ids, for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error { failOpen(peripheral.identifier, error: error); return }
        guard let request = openRequests[peripheral.identifier] else { return }
        guard let write = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: request.endpoint.writeCharacteristicUUID)
              }) else {
            failOpen(peripheral.identifier, error: BluetoothSerialError.writeCharacteristicNotFound)
            return
        }
        openRequests.removeValue(forKey: peripheral.identifier)
        let notify = request.endpoint.notifyCharacteristicUUID.flatMap { id in
            service.characteristics?.first { $0.uuid == CBUUID(string: id) }
        }
        if let notify { peripheral.setNotifyValue(true, for: notify) }
        let sessionID = UUID()
        sessions[sessionID] = Session(
            runID: request.runID, peripheral: peripheral, write: write, notify: notify
        )
        _ = request.gate.resume(returning: sessionID)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            self?.expire(sessionID: sessionID)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let waiter = writeWaiters.removeValue(forKey: peripheral.identifier) else { return }
        if let error { _ = waiter.resume(throwing: error) }
        else { _ = waiter.resume(returning: ()) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        for (id, var session) in sessions where session.peripheral.identifier == peripheral.identifier {
            session.received.append(value)
            sessions[id] = session
        }
    }

    private func failOpen(_ peripheralID: UUID, error: Error) {
        guard let request = openRequests.removeValue(forKey: peripheralID) else { return }
        _ = request.gate.resume(throwing: error)
    }

    private func expire(sessionID: UUID) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        central.cancelPeripheralConnection(session.peripheral)
    }
}

private final class BLEContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
import FloePersistence
import FloeTools
import FloeToolboxCore
@testable import FloeApp

@Suite("Bluetooth automatic connection App contracts", .serialized)
@MainActor struct BluetoothAutoConnectionAppContractTests {
    private let id = UUID(uuidString: "CF92DE24-5AA4-4383-A2F4-9382F7D76743")!
    private func endpoint() -> BluetoothSerialEndpoint {
        .init(peripheralID: id, serviceUUID: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
              writeCharacteristicUUID: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
              notifyCharacteristicUUID: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    }
    @Test func ordinaryInputNeedsOnlyADeviceAndExplicitLegacyChannelsRemainValidated() throws {
        var value = ToolboxConnectionSetup(); value.serial.connection = .bluetooth
        #expect(value.inputIssues(for: .serialAssistant) == [.bluetoothDeviceRequired])
        value.bluetoothPeripheralID = id
        #expect(value.inputIssues(for: .serialAssistant).isEmpty && value.bluetooth == nil)
        value.bluetooth = endpoint()
        #expect(value.inputIssues(for: .serialAssistant).isEmpty)
        value.bluetooth?.serviceUUID = "invalid"
        #expect(value.inputIssues(for: .serialAssistant) == [.invalidBluetoothChannel])
        value.bluetooth = endpoint(); value.bluetoothPeripheralID = UUID()
        #expect(value.inputIssues(for: .serialAssistant) == [.invalidBluetoothChannel])
    }
    @Test func successfulResolvedChannelIsSavedReopenedAndFilledWithoutConnecting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BLEHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent.json")
        let history = ToolboxHistoryStore(fileURL: url)
        var setup = ToolboxConnectionSetup(); setup.serial.connection = .bluetooth; setup.bluetoothPeripheralID = id
        let config = try #require(ToolboxHistoryConfiguration.connection(tool: .serialAssistant, setup: setup))
        // This old-format configuration has no endpoint key. It still loads and
        // requires a new device selection; loading never starts a connection.
        let old = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ToolboxHistoryConfiguration.self, from: old).bluetooth == nil)
        let attempt = UUID(); history.begin(config, attemptID: attempt)
        history.finish(attempt, outcome: .ready, resolvedBluetooth: endpoint())
        #expect(!history.persistenceFailed)
        let reopened = ToolboxHistoryStore(fileURL: url)
        let record = try #require(reopened.records(for: .serialAssistant).first)
        #expect(record.outcome == .ready && record.configuration.bluetooth == endpoint())
        let restored = try #require(record.configuration.connectionSetup())
        #expect(restored.bluetooth == endpoint() && restored.bluetoothPeripheralID == id)
        #expect(restored.inputIssues(for: .serialAssistant).isEmpty)
    }
    @Test func cancelledOrReplacedHistoryAttemptCannotAdoptALateChannel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BLEHistoryFence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ToolboxHistoryStore(fileURL: directory.appendingPathComponent("recent.json"))
        var setup = ToolboxConnectionSetup(); setup.serial.connection = .bluetooth; setup.bluetoothPeripheralID = id
        let config = try #require(ToolboxHistoryConfiguration.connection(tool: .serialAssistant, setup: setup))
        let old = UUID(); history.begin(config, attemptID: old); history.finish(old, outcome: .cancelled)
        history.finish(old, outcome: .ready, resolvedBluetooth: endpoint())
        #expect(history.records(for: .serialAssistant).first?.configuration.bluetooth == nil)
        let next = UUID(); history.begin(config, attemptID: next)
        history.finish(old, outcome: .ready, resolvedBluetooth: endpoint())
        #expect(history.records(for: .serialAssistant).first?.attemptID == next)
        #expect(history.records(for: .serialAssistant).first?.configuration.bluetooth == nil)
        history.finish(next, outcome: .cancelled)
    }
    @Test func existingOpenToolAcceptsAutomaticInputAndReturnsActualChannelOrChoicesWithoutSending() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let service = AppBLE(known: endpoint())
        let tool = BluetoothSerialOpenTool(service: service, store: RemoteHostStore(database: database))
        let registry = ToolRunnerRegistry(); registry.register(tool)
        let runner = try #require(registry.runner(named: "bluetooth.serial.open"))
        let input = try JSONSerialization.data(withJSONObject: ["peripheralID": id.uuidString])
        let run = UUID(); let context = ToolContext(runID: run, cancellation: CancellationToken())
        let result = try await runner.execute(argumentsJSON: input, context: context)
        let receipt = try #require(JSONSerialization.jsonObject(with: Data(result.summary.utf8)) as? [String: Any])
        let channel = try #require(receipt["endpoint"] as? [String: Any])
        #expect(channel["serviceUUID"] as? String == endpoint().serviceUUID)
        #expect(receipt["sessionID"] as? String == service.sessionID.uuidString)
        #expect(receipt["persisted"] as? Bool == false && service.owner == run && service.exchangeCount == 0)
        await service.close(runID: run, sessionID: service.sessionID)

        service.channels = [ .init(endpoint: endpoint(), recognition: .unverified) ]
        let choices = try await runner.execute(argumentsJSON: input, context: context)
        let choice = try #require(JSONSerialization.jsonObject(with: Data(choices.summary.utf8)) as? [String: Any])
        #expect(choice["status"] as? String == "channelSelectionRequired" && choice["sessionID"] == nil)
        #expect(service.openCount == 1 && service.exchangeCount == 0)
        let explicit = try JSONSerialization.data(withJSONObject: ["peripheralID":id.uuidString,
            "serviceUUID":endpoint().serviceUUID, "writeCharacteristicUUID":endpoint().writeCharacteristicUUID,
            "notifyCharacteristicUUID":endpoint().notifyCharacteristicUUID!])
        _ = try await runner.execute(argumentsJSON: explicit, context: context)
        #expect(service.openCount == 2 && service.exchangeCount == 0)
        await service.close(runID: run, sessionID: service.sessionID)
    }
    @Test func cancelledToolContextCannotPublishOrRetainALateOpenedSession() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let service = AppBLE(known: endpoint()); let cancellation = CancellationToken()
        service.onOpen = { cancellation.cancel() }
        let tool = BluetoothSerialOpenTool(service: service, store: RemoteHostStore(database: database))
        let args = try JSONDecoder().decode(BluetoothSerialOpenTool.Arguments.self,
            from: JSONSerialization.data(withJSONObject: ["peripheralID":id.uuidString]))
        await #expect(throws: FloeError.cancelled) {
            _ = try await tool.execute(args, context: .init(runID: UUID(), cancellation: cancellation))
        }
        #expect(service.owner == nil && service.openCount == 1 && service.exchangeCount == 0)
    }
    @Test func existingToolAndUIKeepAuthenticationDistinctAndNeverReportASessionOnFailure() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let service = AppBLE(known: endpoint()); service.openError = .authenticationRequired
        let tool = BluetoothSerialOpenTool(service: service, store: RemoteHostStore(database: database))
        let args = try JSONDecoder().decode(BluetoothSerialOpenTool.Arguments.self,
            from: JSONSerialization.data(withJSONObject: ["peripheralID":id.uuidString]))
        await #expect(throws: BluetoothSerialError.authenticationRequired) {
            _ = try await tool.execute(args, context: .init(runID: UUID(), cancellation: CancellationToken()))
        }
        #expect(service.exchangeCount == 0)
        #expect(ToolboxBluetoothPresentation.message(BluetoothSerialError.authenticationRequired)
            != ToolboxBluetoothPresentation.message(BluetoothSerialError.permissionDenied))
        #expect(BluetoothSerialOpenTool.name == "bluetooth.serial.open" && BluetoothSerialOpenTool.toolEffect == .mutating)
    }
}

@MainActor private final class AppBLE: BluetoothSerialServicing {
    let sessionID = UUID()
    var channels: [BluetoothSerialChannel]
    var openCount = 0, exchangeCount = 0
    var owner: UUID?
    var openError: BluetoothSerialError?
    var onOpen: (() -> Void)?
    init(known: BluetoothSerialEndpoint) { channels = [.init(endpoint: known, recognition: .nordicUART)] }
    func scan(duration: TimeInterval) async throws -> [BluetoothSerialPeripheral] { [] }
    func discoverChannels(runID: UUID, peripheralID: UUID, timeout: TimeInterval) async throws -> [BluetoothSerialChannel] { channels }
    func open(runID: UUID, endpoint: BluetoothSerialEndpoint, timeout: TimeInterval) async throws -> UUID {
        if let openError { throw openError }; owner = runID; openCount += 1; onOpen?(); return sessionID
    }
    func exchange(runID: UUID, sessionID: UUID, data: Data?, wait: TimeInterval, maxBytes: Int) async throws -> Data { exchangeCount += 1; return Data() }
    func close(runID: UUID, sessionID: UUID) async { if owner == runID { owner = nil } }
}
#endif

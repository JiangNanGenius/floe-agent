// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameDeveloperCore
import FloeGameCore

private actor MemoryGuestFilePort: GameDeveloperGuestFilePort {
    var files: [String: Data] = [:]
    var gold = 120
    var corruptRequestID = false
    var held = false

    func writeFile(_ data: Data, relativePath: String,
                   directory: GameDeveloperGuestDirectory) async throws {
        files[relativePath] = data
        guard relativePath.hasSuffix(".req") else { return }
        guard let responsePath = relativePath.split(separator: "/").last.map({ "responses/" + $0.replacingOccurrences(of: ".req", with: ".res") }) else { return }
        let bytes = [UInt8](data)
        guard bytes.count >= 46, Array(bytes.prefix(4)) == GameDeveloperRGSSCodec.requestMagic else { return }
        let operation = GameDeveloperRGSSOperation(rawValue: bytes[5])
        let uuidString = String(decoding: bytes[6..<42], as: UTF8.self)
        let requestID = UUID(uuidString: uuidString) ?? UUID()
        let length = Int((UInt32(bytes[42]) << 24) | (UInt32(bytes[43]) << 16) |
                         (UInt32(bytes[44]) << 8) | UInt32(bytes[45]))
        let payload = Data(bytes[46..<(46 + length)])
        let records = try GameDeveloperRGSSCodec.decodeRecords(payload)
        var response: [GameDeveloperRGSSRecord] = [
            .init("@status", .integer(0)), .init("@revision", .integer(3))
        ]
        switch operation {
        case .probe:
            response += [
                .init("@overlayVersion", .string("1.0.0")),
                .init("@engine", .string("rpgMakerXP")),
                .init("@runtime", .string("RGSS test")),
                .init("@actorCount", .integer(1)),
                .init("actor.0.id", .integer(1)),
                .init("actor.0.name", .string("Hero")),
                .init("actor.0.level", .integer(5)),
                .init("actor.0.hp", .integer(100)),
                .init("actor.0.maxHP", .integer(100)),
                .init("actor.0.mp", .integer(20)),
                .init("actor.0.maxMP", .integer(20)),
                .init("@itemCount", .integer(10)),
                .init("@variableCount", .integer(5)),
                .init("@switchCount", .integer(5)),
                .init("@mapCount", .integer(3)),
                .init("@levelAction", .boolean(true)),
                .init("@resetAvailable", .boolean(true)),
                .init("@snapshotAvailable", .boolean(true))
            ]
        case .read:
            response += [
                .init("field.party.gold", .integer(gold)),
                .init("field.party.actors", .string("Hero L5 HP100/100")),
                .init("field.party.actor.1.level", .integer(5)),
                .init("field.party.actor.1.hp", .integer(100)),
                .init("field.party.actor.1.sp", .integer(20)),
                .init("field.party.items", .string("Potion x2")),
                .init("field.map.id", .integer(1)),
                .init("field.player.x", .integer(4)),
                .init("field.player.y", .integer(6)),
                .init("field.system.playtime", .string("00:01:00")),
                .init("field.system.frames", .integer(600)),
                .init("field.variables.v1", .string("7")),
                .init("field.switches.s1", .boolean(true))
            ]
        case .write:
            let values = GameDeveloperRGSSCodec.dictionary(records)
            if values["change.0.id"]?.stringValue == "party.gold",
               let newGold = values["change.0.value"]?.integerValue {
                gold = newGold
                response.append(.init("@status", .integer(0)))
                response.append(.init("changed.0", .string("party.gold")))
                response.append(.init("field.party.gold", .integer(gold)))
            } else {
                response.append(.init("@status", .integer(1)))
            }
        case .invoke:
            response.append(.init("@status", .integer(0)))
        case .snapshot:
            response.append(.init("@snapshot", .binary(Data("snapshot-v1".utf8))))
        case .restore:
            if let snapshot = records.first(where: { $0.key == "snapshot" })?.value.binaryValue,
               snapshot == Data("snapshot-v1".utf8) {
                gold = 999
            }
        case .reset:
            response.append(.init("@message", .string("Returned to title.")))
        case .diagnostics:
            response += [.init("@fps", .integer(60)), .init("@frames", .integer(600)), .init("@mapID", .integer(1))]
        case .detach, .none:
            break
        }
        let responseID = corruptRequestID ? UUID() : requestID
        files[responsePath] = try GameDeveloperRGSSCodec.encodeResponse(
            requestID: responseID, records: response)
    }

    func readFile(relativePath: String, directory: GameDeveloperGuestDirectory,
                  maximumBytes: Int) async throws -> Data? {
        guard let data = files[relativePath] else { return nil }
        guard data.count <= maximumBytes else { throw GameDeveloperError.payloadTooLarge("test file") }
        return data
    }

    func removeFile(relativePath: String, directory: GameDeveloperGuestDirectory) async throws {
        files.removeValue(forKey: relativePath)
    }
}

private func guestDirectory() throws -> GameDeveloperGuestDirectory {
    try .init(absolutePath: "/run/project/floe-developer", ownerToken: UUID())
}

private func guestBinding() -> GameDeveloperSessionBinding {
    DeveloperTestSupport.binding(engine: .rpgMakerXP)
}

@Test func guestTLVRoundTripsTypedRecords() throws {
    let id = UUID()
    let records: [GameDeveloperRGSSRecord] = [
        .init("field.party.gold", .integer(123)),
        .init("field.player.x", .number(12.5)),
        .init("field.switches.s1", .boolean(true)),
        .init("field.party.actors", .string("Hero")),
        .init("binary", .binary(Data([1, 2, 3]))),
        .init("empty", .null)
    ]
    let request = try GameDeveloperRGSSCodec.encodeRequest(operation: .write, requestID: id, records: records)
    #expect(Array(request.prefix(4)) == GameDeveloperRGSSCodec.requestMagic)
    let response = try GameDeveloperRGSSCodec.encodeResponse(requestID: id, records: records)
    let decoded = try GameDeveloperRGSSCodec.decodeResponse(response, expectedRequestID: id)
    #expect(decoded == records)
}

@Test func guestTLVRejectsAStaleRequestID() throws {
    let id = UUID()
    let response = try GameDeveloperRGSSCodec.encodeResponse(
        requestID: UUID(), records: [.init("@status", .integer(0))])
    #expect(throws: GameDeveloperError.self) {
        _ = try GameDeveloperRGSSCodec.decodeResponse(response, expectedRequestID: id)
    }
}

@Test func guestSchemaExposesRealRGSSControls() {
    let probe = GameDeveloperRGSSProbe(
        engine: .rpgMakerXP, overlayVersion: "1.0.0", runtime: "RGSS test",
        actors: [.init(id: 1, name: "Hero", level: 5, hp: 100, maxHP: 100, mp: 20, maxMP: 20)],
        itemCount: 10, variableCount: 5, switchCount: 5, mapCount: 3,
        levelAction: true, resetAvailable: true, snapshotAvailable: true)
    let fields = GameDeveloperRGSSSchema.fields(engine: .rpgMakerXP, probe: probe)
    let fieldIDs = Set(fields.map(\.id))
    #expect(fieldIDs.contains("party.gold"))
    #expect(fieldIDs.contains("party.actor.1.hp"))
    #expect(fieldIDs.contains("party.actor.1.sp"))
    #expect(!fieldIDs.contains("party.actor.1.mp"))
    #expect(fieldIDs.contains("variables.v1"))
    #expect(fieldIDs.contains("switches.s1"))
    let actions = GameDeveloperRGSSSchema.actions(engine: .rpgMakerXP, probe: probe)
    let actionIDs = Set(actions.map(\.id))
    #expect(actionIDs.contains("party.gainGold"))
    #expect(actionIDs.contains("party.healAll"))
    #expect(actionIDs.contains("party.levelAll"))
    #expect(actionIDs.contains("party.addItem"))
    #expect(actionIDs.contains("player.transfer"))
    #expect(actions.allSatisfy { !$0.parameters.isEmpty || $0.id != "party.addItem" })
    #expect(GameDeveloperRGSSSchema.supports(probe: probe).snapshot)
}

@MainActor
@Test func guestTransportAttachesReadsWritesAndSnapshots() async throws {
    let port = MemoryGuestFilePort()
    let transport = try GameDeveloperRGSSGuestTransport(
        binding: guestBinding(), directory: try guestDirectory(), port: port)
    let receipt = try await transport.attach()
    #expect(receipt.runtime == "RGSS test")

    let sessionID = UUID()
    let probe = try await transport.exchange(.init(
        sessionID: sessionID, requestID: UUID(), operation: .probe,
        payload: GameDeveloperWire.emptyPayload()))
    let capabilities = try GameDeveloperWire.decodeCapabilities(
        probe.value, expectedEngine: .rpgMakerXP, limits: .default)
    #expect(capabilities.fields.contains { $0.id == "party.gold" })
    #expect(capabilities.actions.contains { $0.id == "party.gainGold" })

    let read = try await transport.exchange(.init(
        sessionID: sessionID, requestID: UUID(), operation: .read,
        payload: GameDeveloperWire.emptyPayload()))
    let state = try GameDeveloperWire.decodeState(read.value, capabilities: capabilities, limits: .default)
    #expect(state.values["party.gold"] == .integer(120))

    let write = try await transport.exchange(.init(
        sessionID: sessionID, requestID: UUID(), operation: .write,
        payload: try GameDeveloperWire.encodeChanges(
            [.init(id: "party.gold", value: .integer(42))], limits: .default)))
    let outcome = try GameDeveloperWire.decodeOutcome(
        write.value, expectedActionID: "fields.write", capabilities: capabilities, limits: .default)
    #expect(outcome.status == .applied)
    #expect(outcome.state?.values["party.gold"] == .integer(42))

    let snapshot = try await transport.exchange(.init(
        sessionID: sessionID, requestID: UUID(), operation: .snapshot,
        payload: GameDeveloperWire.emptyPayload()))
    let snapshotData = try GameDeveloperWire.decodeSnapshot(
        snapshot.value, expectedEngine: .rpgMakerXP, limits: .default)
    #expect(!snapshotData.isEmpty)
}

@MainActor
@Test func guestTransportRejectsStaleResponse() async throws {
    let port = MemoryGuestFilePort()
    let transport = try GameDeveloperRGSSGuestTransport(
        binding: guestBinding(), directory: try guestDirectory(), port: port)
    _ = try await transport.attach()
    await port.setCorrupt(true)
    await #expect(throws: GameDeveloperError.self) {
        _ = try await transport.exchange(.init(
            sessionID: UUID(), requestID: UUID(), operation: .read,
            payload: GameDeveloperWire.emptyPayload()))
    }
}

private extension MemoryGuestFilePort {
    func setCorrupt(_ value: Bool) { corruptRequestID = value }
}

@Test(arguments: [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce])
func guestSchemaUsesEngineSpecificMPShape(_ engine: GameEngineID) {
    let probe = GameDeveloperRGSSProbe(
        engine: engine, overlayVersion: "1.0.0", runtime: "RGSS test",
        actors: [.init(id: 1, name: "Hero", level: 5, hp: 100, maxHP: 100, mp: 20, maxMP: 20)],
        itemCount: 10, variableCount: 5, switchCount: 5, mapCount: 3,
        levelAction: true, resetAvailable: true, snapshotAvailable: true)
    let fields = GameDeveloperRGSSSchema.fields(engine: engine, probe: probe)
    let ids = Set(fields.map(\.id))
    if engine == .rpgMakerXP {
        #expect(ids.contains("party.actor.1.sp"))
        #expect(!ids.contains("party.actor.1.mp"))
        #expect(fields.first { $0.id == "party.actor.1.sp" }?.label.contains("SP") == true)
    } else {
        #expect(ids.contains("party.actor.1.mp"))
        #expect(!ids.contains("party.actor.1.sp"))
        #expect(fields.first { $0.id == "party.actor.1.mp" }?.label.contains("MP") == true)
    }
}

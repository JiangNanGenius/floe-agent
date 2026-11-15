// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreFoundation
@testable import FloeGameDeveloperCore
import FloeGameCore

@MainActor
@Test func attachDiscoversCapabilitiesAndState() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    #expect(session.phase == .ready)
    #expect(session.capabilities?.engine == .phaser)
    #expect(session.fields.count == 6)
    #expect(session.actions.count == 4)
    #expect(session.state?.values["party.gold"] == .integer(120))
    #expect(session.checkpoints.contains { $0.kind == .baseline && $0.isComplete })
}

@MainActor
@Test func fieldWriteAppliesAndReadsBack() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let outcome = try await session.write([.init(id: "party.gold", value: .integer(777))])
    #expect(outcome.status == .applied)
    #expect(session.state?.values["party.gold"] == .integer(777))
    #expect(session.history.first?.actionID == "fields.write")
    #expect(session.checkpoints.contains { $0.kind == .beforeFieldWrite })
}

@MainActor
@Test func actionAppliesAndReadsBack() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let outcome = try await session.invoke("party.gainGold", arguments: ["amount": .integer(30)])
    #expect(outcome.actionID == "party.gainGold")
    #expect(outcome.status == .applied)
    #expect(session.state?.values["party.gold"] == .integer(150))
    #expect(session.history.first?.label == "Gain gold")
}

@MainActor
@Test func unsupportedActionIsReported() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.invoke("party.destroy", confirmed: true)
    }
    #expect(session.history.first?.status == .unsupported)
}

@MainActor
@Test func destructiveActionNeedsConfirmation() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.invoke("party.destroy")
    }
}

@MainActor
@Test func staleResponseIDsAreRejected() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    transport.responseRequestID = UUID()
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.write([.init(id: "party.gold", value: .integer(1))])
    }
}

@MainActor
@Test func staleSessionAfterDetachIsRejected() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    transport.responseDelay = .milliseconds(150)
    let task = Task { @MainActor in
        try await session.write([.init(id: "party.gold", value: .integer(42))])
    }
    try await Task.sleep(for: .milliseconds(20))
    session.detach()
    await #expect(throws: GameDeveloperError.self) {
        _ = try await task.value
    }
    #expect(session.phase == .detached)
}

@MainActor
@Test func checkpointCapturesAndReverts() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    _ = try await session.write([.init(id: "party.gold", value: .integer(500))])
    let checkpoint = try #require(session.checkpoints.first { $0.kind == .beforeFieldWrite })
    #expect(session.state?.values["party.gold"] == .integer(500))
    _ = try await session.revert(to: checkpoint.id)
    #expect(session.state?.values["party.gold"] == .integer(120))
}

@MainActor
@Test func baselineResetRestoresSessionStart() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    _ = try await session.write([.init(id: "party.gold", value: .integer(999))])
    let outcome = try await session.reset(.baseline, confirmed: true)
    #expect(outcome.status == .applied)
    #expect(session.state?.values["party.gold"] == .integer(120))
}

@MainActor
@Test func resetRequiresConfirmation() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.reset(.restart, confirmed: false)
    }
}

@MainActor
@Test func hostileWriteValuesAreRejectedBeforeTransport() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let before = transport.lastWrite
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.write([.init(id: "__proto__", value: .integer(1))])
    }
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.write([.init(id: "party.gold", value: .text("12"))])
    }
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.write([.init(id: "party.gold", value: .integer(100_000_000))])
    }
    #expect(transport.lastWrite == before)
}

@MainActor
@Test func payloadBoundsAreEnforced() async throws {
    let limits = try GameDeveloperLimits(maximumChangesPerRequest: 2)
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport, limits: limits)
    try await session.attach()
    await #expect(throws: GameDeveloperError.self) {
        _ = try await session.write([
            .init(id: "party.gold", value: .integer(1)),
            .init(id: "player.x", value: .number(1)),
            .init(id: "engine.speed", value: .number(1))
        ])
    }
}

@MainActor
@Test func fractionalReadOnlyStateRendersAndRoundTrips() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let roll = try #require(session.capabilities?.field("camera.roll"))
    #expect(session.state?.values["camera.roll"] == .number(1.25))
    #expect(GameDeveloperValue.number(1.25).displayText == "1.25")
    #expect(throws: Never.self) {
        try GameDeveloperWire.validate(value: .number(1.25), against: roll, limits: .default)
    }
}

@MainActor
@Test func staleRefreshDoesNotOverwriteAMutation() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    transport.responseDelay = .milliseconds(150)
    let refresh = Task { await session.refresh() }
    try await Task.sleep(for: .milliseconds(30))
    let write = Task { try await session.write([.init(id: "party.gold", value: .integer(777))]) }
    _ = try await write.value
    await refresh.value
    transport.responseDelay = nil
    #expect(session.state?.values["party.gold"] == .integer(777))
}

@MainActor
@Test func lateCapabilityRegistrationIsDiscovered() async throws {
    let transport = FakeDeveloperTransport()
    let session = try GameDeveloperSession(transport: transport)
    try await session.attach()
    let base = DeveloperTestSupport.capabilities()
    let extended = GameDeveloperCapabilities(
        protocolVersion: base.protocolVersion,
        bridgeVersion: base.bridgeVersion,
        engine: base.engine,
        runtime: base.runtime,
        supports: base.supports,
        fields: base.fields + [
            .init(id: "late.field", label: "Late", labelZhHans: "稍后",
                  group: "Late", groupZhHans: "稍后", kind: .readOnlyNumber)
        ],
        actions: base.actions,
        notices: base.notices,
        diagnostics: base.diagnostics)
    transport.capabilities = extended
    try await session.refreshCapabilities()
    #expect(session.capabilities?.field("late.field") != nil)
}

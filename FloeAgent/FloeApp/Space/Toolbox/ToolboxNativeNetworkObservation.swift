// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeToolboxCore
import FloeToolboxDiagnostics

nonisolated struct ToolboxNetworkObservationInput: Decodable, Sendable {
    enum Action: String, Decodable, Sendable { case current, roamingStatus }
    let action: Action
    private struct Field: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard Set(c.allKeys.map(\.stringValue)) == ["action"], let field = Field(stringValue: "action") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Observation accepts only action; no target, permissions or trace control"))
        }
        action = try c.decode(Action.self, forKey: field)
    }
}

nonisolated struct ToolboxNativeRoamingState: Sendable {
    let running: Bool
    let latestAttemptFailed: Bool
    let hasRetainedSnapshot: Bool
    let snapshotIsCurrentAttempt: Bool
    let snapshot: RoamingSnapshot?
}

nonisolated struct ToolboxRoamingObservationReport: Encodable, Sendable {
    let running: Bool
    let latestAttemptFailed: Bool
    let snapshotState: String
    let hasRetainedSnapshot: Bool
    let snapshotIsCurrentAttempt: Bool
    let retainedSampleCount: Int?
    let retainedEventCount: Int?
    let droppedSamples: UInt64?
    let droppedEvents: UInt64?
    let accessPointChanges: UInt64?
    let lastObservedAt: String?
    let packetLoss: Double?
    let meanLatencyMilliseconds: Double?
    let source = "Existing native Toolbox workbench trace, not a task-owned session or a new trace. This read cannot start/stop it; no target, payload, SSID or BSSID history is exposed. Probe loss describes those ICMP probes only."
}

@MainActor enum ToolboxNativeNetworkObservation {
    private struct Permission: Encodable {
        let canReadIdentity: Bool
        let preciseLocationAuthorized: Bool
        let authorizationStatus: Int
        let requestedPermission = false
    }
    private nonisolated struct Identity: Encodable, Sendable {
        let status: String
        let identityStatus: String
        let ssid: String?
        let bssid: String?
        let signalDBM: Int?
    }
    private nonisolated struct Gateway: Encodable, Sendable { let status: String; let address: String? }
    private struct Receipt: Encodable {
        let action: String
        let startedAt: String
        let completedAt: String
        let permission: Permission
        let currentWiFi: Identity?
        let gateway: Gateway?
        let roaming: ToolboxRoamingObservationReport
        let source = "Native device observation using existing authorization only. ISO8601 read-completion/sample times. No new permission request, GPS fix, Linux environment, connection, packet capture or trace is created. Missing AP identity/RSSI remains missing."
    }
    private static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func roaming(_ state: ToolboxNativeRoamingState, mayReadIdentity: Bool) -> ToolboxRoamingObservationReport {
        let snapshot = state.running && !state.snapshotIsCurrentAttempt ? nil : state.snapshot
        let kind = snapshot == nil ? (state.running ? "startingWithoutCurrentSamples" : "noPublishedSnapshot")
            : state.running ? "currentRunningSnapshot" : "retainedSnapshotNotLive"
        return .init(running: state.running, latestAttemptFailed: state.latestAttemptFailed, snapshotState: kind,
            hasRetainedSnapshot: state.hasRetainedSnapshot, snapshotIsCurrentAttempt: state.snapshotIsCurrentAttempt,
            retainedSampleCount: snapshot?.samples.count, retainedEventCount: snapshot?.events.count,
            droppedSamples: snapshot?.droppedSamples, droppedEvents: snapshot?.droppedEvents,
            accessPointChanges: mayReadIdentity ? snapshot?.totalAccessPointChanges : nil,
            lastObservedAt: snapshot?.samples.last.map { time($0.observation.timestamp) },
            packetLoss: snapshot?.packetLoss, meanLatencyMilliseconds: snapshot?.meanLatencyMilliseconds)
    }
    private nonisolated static func readWiFi(_ allowed: Bool) async throws -> Identity {
        do {
            let value = try await WiFiObservationService.current(mayReadIdentity: allowed)
            let validBSSID = value.bssid.flatMap { raw -> String? in
                let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }),
                      !["00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"].contains(raw.lowercased()) else { return nil }
                return raw.lowercased()
            }
            let available = allowed && value.status == .wifi
            return .init(status: value.status.rawValue,
                identityStatus: value.status == .notWiFi ? "notConnectedToWiFi" : value.status != .wifi ? "nativeReadUnavailable" : !allowed ? "identityReadUnavailableUnderExistingSystemAuthorization" : validBSSID == nil ? "systemDidNotProvideValidAPIdentity" : "observed",
                ssid: available ? value.ssid.flatMap { $0.utf8.count <= 128 ? $0 : nil } : nil, bssid: available ? validBSSID : nil, signalDBM: available ? value.signalDBM : nil)
        } catch is CancellationError { throw CancellationError() }
        catch DiagnosticError.timedOut { return .init(status: "unavailable", identityStatus: "nativeReadTimedOut", ssid: nil, bssid: nil, signalDBM: nil) }
        catch { return .init(status: "unavailable", identityStatus: "nativeReadUnavailable", ssid: nil, bssid: nil, signalDBM: nil) }
    }
    private nonisolated static func readGateway() async throws -> Gateway {
        do {
            let value = try await WiFiGatewayService.current()
            return .init(status: value == nil ? "notProvided" : "observed", address: value)
        } catch is CancellationError { throw CancellationError() }
        catch DiagnosticError.timedOut { return .init(status: "timedOut", address: nil) }
        catch { return .init(status: "unavailable", address: nil) }
    }
    static func observe(_ input: ToolboxNetworkObservationInput, environment: AppEnvironment, context: ToolContext) async throws -> ToolExecutionOutput {
        let names: Set<String> = [ToolboxNetworkObserveTool.name]
        let task = try await environment.studioCoordinator.conversation(context, allowedNames: names)
        let started = Date(), location = LocationServicesCenter.shared
        location.refreshAuthorizationStatus()
        let allowedBefore = location.canReadWiFiIdentity
        let current: Identity?, gateway: Gateway?
        if input.action == .current {
            async let wifiRead = readWiFi(allowedBefore)
            async let gatewayRead = readGateway()
            (current, gateway) = try await (wifiRead, gatewayRead)
        } else { current = nil; gateway = nil }
        guard try await environment.studioCoordinator.conversation(context, allowedNames: names) == task else { throw FloeError.validationFailed("The native observation owner changed") }
        try context.cancellation.throwIfCancelled(); location.refreshAuthorizationStatus()
        let allowedAfter = location.canReadWiFiIdentity
        let identity: Identity?
        if let current, allowedBefore && !allowedAfter {
            identity = .init(status: current.status, identityStatus: "authorizationChangedDuringRead", ssid: nil, bssid: nil, signalDBM: nil)
        } else { identity = current }
        return try StudioToolOutput.make(Receipt(action: input.action.rawValue, startedAt: time(started), completedAt: time(Date()),
            permission: .init(canReadIdentity: allowedAfter, preciseLocationAuthorized: location.hasPreciseLocationAuthorization, authorizationStatus: Int(location.authorizationStatus.rawValue)),
            currentWiFi: identity, gateway: gateway,
            roaming: roaming(environment.toolboxDiagnostics.nativeObservationState(), mayReadIdentity: allowedAfter)))
    }
}

struct ToolboxNetworkObserveTool: AgentTool {
    typealias Arguments = ToolboxNetworkObservationInput
    static let name = "toolbox.network.observe"
    static let toolDescription = "Read the native device's current Wi-Fi/AP and actual Toolbox roaming status: 当前Wi-Fi、SSID、BSSID、AP地址、漫游状态. action=current performs a fresh native Wi-Fi path/AP/gateway read using existing precise-location authorization; action=roamingStatus reads only existing native workbench trace lifecycle/retained metrics. Missing identity or RSSI is unknown, never generated. It cannot request permission/start GPS, launch a trace, stop the user's workbench, open a connection, inspect another connection's capture or require Linux. Ordinary saved tasks only. A retained trace is explicitly not a new/live sample; ICMP losses are not all-network failure."
    static let parametersJSON = #"{"type":"object","additionalProperties":false,"required":["action"],"properties":{"action":{"type":"string","enum":["current","roamingStatus"]}}}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    static let requiresHostScope = false
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let observe: @MainActor @Sendable (Arguments, ToolContext) async throws -> ToolExecutionOutput
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard context.executionToolName == Self.name, context.allowedToolNames?.contains(Self.name) == true,
              context.frozenEffectiveCatalogNames?.contains(Self.name) == true else { throw FloeError.validationFailed("Native network observation is outside this task's effective tools") }
        let worker = Task { try await observe(args, context) }
        let monitor = Task {
            while !Task.isCancelled {
                if context.cancellation.isCancelled { worker.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
#endif

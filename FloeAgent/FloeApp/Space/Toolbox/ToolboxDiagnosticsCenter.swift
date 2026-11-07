// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import CoreLocation
import FloePersistence
import FloeToolboxCore
import FloeToolboxDiagnostics
import FloeToolboxWorkbenches

@MainActor final class ToolboxDiagnosticsCenter: ObservableObject {
    @Published private(set) var models: [ToolboxTool: DiagnosticWorkbenchModel] = [:]
    @Published private(set) var roaming: RoamingSnapshot?
    @Published private(set) var tracing = false
    @Published private(set) var failed = false
    @Published private(set) var defaultGateway: String?
    @Published private(set) var wifiIdentity: WiFiIdentity?
    @Published private(set) var readingNetwork = false
    private var networkReadGeneration = UUID()
    private let database: DatabaseManager
    private var leases: [ToolboxTool: SessionLease] = [:]
    private var sampler: RoamingSampler?
    private var observer: Task<Void, Never>?
    private var traceGeneration = UUID()
    init(database: DatabaseManager) { self.database = database }
    var canReadWiFiIdentity: Bool { LocationServicesCenter.shared.canReadWiFiIdentity }
    var needsInitialWiFiAuthorization: Bool { LocationServicesCenter.shared.authorizationStatus == .notDetermined }
    var wifiIdentityMessage: String? {
        if !canReadWiFiIdentity {
            return IDELanguageRunText.t("允许精确定位后可显示当前 Wi-Fi 名称和 AP 地址。", "Allow Precise Location to show the current Wi-Fi name and AP address.")
        }
        if wifiIdentity?.status == .notWiFi {
            return IDELanguageRunText.t("当前未连接 Wi-Fi。", "Not currently connected to Wi-Fi.")
        }
        if wifiIdentity?.bssid == nil {
            return IDELanguageRunText.t("系统尚未返回当前接入点信息。", "The system has not provided the current AP information.")
        }
        return nil
    }
    func refreshNetworkInfo() async {
        let generation = UUID(); networkReadGeneration = generation
        readingNetwork = true
        defer { if networkReadGeneration == generation { readingNetwork = false } }
        LocationServicesCenter.shared.refreshAuthorizationStatus()
        let gateway = try? await WiFiGatewayService.current()
        guard generation == networkReadGeneration, !Task.isCancelled else { return }
        defaultGateway = gateway
        let identity = try? await WiFiObservationService.current(mayReadIdentity: canReadWiFiIdentity)
        guard generation == networkReadGeneration, !Task.isCancelled else { return }
        wifiIdentity = identity
    }
    func requestWiFiIdentityAuthorization() async {
        _ = await LocationServicesCenter.shared.requestWiFiIdentityAuthorization()
        guard !Task.isCancelled else { return }
        await refreshNetworkInfo()
    }
    func model(for tool: ToolboxTool) throws -> DiagnosticWorkbenchModel {
        if let existing = models[tool] { return existing }
        let lease = SessionLease(ownerID: UUID()); leases[tool] = lease
        let service = DiagnosticService(lease: lease, authorize: { [weak self] expected, _, _ in
            await self?.isCurrent(tool, lease: expected) == true
        })
        let model = try DiagnosticWorkbenchModel(tool: tool, service: service, mayReadWiFiIdentity: canReadWiFiIdentity)
        models[tool] = model
        return model
    }
    private func isCurrent(_ tool: ToolboxTool, lease: SessionLease) -> Bool { leases[tool] == lease }
    func closeNow(_ tool: ToolboxTool) {
        leases[tool] = nil
        let model = models.removeValue(forKey: tool)
        Task { await model?.close() }
        if tool == .roaming { stopTraceNow() }
    }
    func leaveNow() {
        networkReadGeneration = UUID(); readingNetwork = false
        for tool in Array(models.keys) { closeNow(tool) }
        stopTraceNow()
    }
    func startTrace(target: String, interval: Double) {
        let generation = UUID(); traceGeneration = generation
        observer?.cancel()
        tracing = true; failed = false
        observer = Task { [weak self] in
            guard let self else { return }
            await sampler?.stop(); sampler = nil
            let lease = SessionLease(ownerID: UUID()); leases[.roaming] = lease
            let authorize: DiagnosticAuthorizer = { [weak self] expected, _, _ in
                await self?.isCurrent(.roaming, lease: expected) == true
            }
            let diagnostic = DiagnosticService(lease: lease, authorize: authorize)
            do {
                let root = try PersonalContentLibrary.applicationRoot().deletingLastPathComponent().appendingPathComponent("Toolbox/Exports", isDirectory: true)
                let journal = try await CaptureJournal(ownerID: lease.ownerID, captureID: lease.sessionID,
                    repository: ToolboxCaptureStore(database: database, exportRoot: root), limits: CaptureLimits())
                let configuration = try RoamingConfiguration(target: target, probeInterval: interval)
                let service = try RoamingSampler(lease: lease, configuration: configuration, journal: journal,
                    identity: { [weak self] in
                        let allowed = await self?.canReadWiFiIdentity ?? false
                        return try await WiFiObservationService.current(mayReadIdentity: allowed)
                    },
                    probe: { host in
                        guard let result = try await diagnostic.ping(target: host, count: 1).first else { return .timeout }
                        if case .reply(let milliseconds) = result.status { return .reply(milliseconds: milliseconds) }
                        return .timeout
                    }, authorize: authorize)
                guard traceGeneration == generation, !Task.isCancelled else { await diagnostic.stop(); return }
                sampler = service
                try await service.start()
                while traceGeneration == generation, !Task.isCancelled {
                    let snapshot = await service.snapshot(), state = await service.state()
                    guard traceGeneration == generation, !Task.isCancelled else { break }
                    roaming = snapshot
                    if let observation = snapshot.samples.last(where: { $0.observation.status != .notObserved })?.observation {
                        wifiIdentity = WiFiIdentity(status: observation.status, ssid: observation.ssid,
                            bssid: observation.bssid, signalDBM: observation.signalDBM)
                    }
                    if !state.running { tracing = false; failed = state.error != nil; break }
                    try await Task.sleep(for: .seconds(1))
                }
                await service.stop(); await diagnostic.stop()
            } catch {
                await diagnostic.stop()
                guard traceGeneration == generation else { return }
                tracing = false; failed = !(error is CancellationError)
            }
        }
    }
    func stopTraceNow() {
        traceGeneration = UUID(); leases[.roaming] = nil
        observer?.cancel(); observer = nil
        let previous = sampler; sampler = nil
        Task { await previous?.stop() }; tracing = false
    }
    func stopTrace() async { stopTraceNow() }
}
#endif

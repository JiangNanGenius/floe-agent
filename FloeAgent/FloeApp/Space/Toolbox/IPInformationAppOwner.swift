// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import SwiftUI
import FloeToolboxDiagnostics
import FloeToolboxIPInformation

/// One AppEnvironment-owned loader. Layout/view reconstruction never creates
/// a second database owner and does not cancel this actor's updates.
@MainActor
final class IPInformationAppOwner: ObservableObject {
    enum Phase { case loading, ready(IPInformationService), failed }
    @Published private(set) var phase: Phase = .loading
    private let storageRoot: URL
    private let onDatabaseChanged: @MainActor @Sendable () -> Void
    private let loadService: @Sendable (URL) async throws -> IPInformationService
    private var observation: Task<Void, Never>?
    private var observedVersion: String?
    private var load: Task<IPInformationService, Error>?
    private var generation = UUID()

    init(storageRoot: URL = URL.applicationSupportDirectory
        .appendingPathComponent("FloeAgent/IPInformation", isDirectory: true),
        onDatabaseChanged: @escaping @MainActor @Sendable () -> Void = {},
        loadService: @escaping @Sendable (URL) async throws -> IPInformationService = {
            try await IPInformationService.open(storageRoot: $0)
        }) {
        self.storageRoot = storageRoot
        self.onDatabaseChanged = onDatabaseChanged; self.loadService = loadService
        start()
    }
    private func start() {
        guard load == nil else { return }
        phase = .loading
        let stamp = UUID(); generation = stamp
        let root = storageRoot, loader = loadService
        let task = Task { try await loader(root) }
        load = task
        Task { [weak self] in
            do {
                let service = try await task.value
                guard let self, self.generation == stamp else { return }
                self.phase = .ready(service)
                self.observe(service)
            } catch {
                guard let self, self.generation == stamp else { return }
                self.phase = .failed
            }
        }
    }
    private func observe(_ service: IPInformationService) {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            for await value in await service.updates() {
                guard !Task.isCancelled, self != nil else { break }
                self?.receive(value)
            }
        }
    }
    private func receive(_ value: IPInformationState) {
        let version = value.metadata?.datasetVersion
        guard version != observedVersion else { return }
        observedVersion = version; onDatabaseChanged()
    }
    deinit { observation?.cancel() }
    func retry() {
        guard case .failed = phase else { return }
        // Retry only a completed failed load; never replace an active actor.
        load = nil; start()
    }
    private func service() async throws -> IPInformationService {
        if case .ready(let service) = phase { return service }
        guard let load else { throw IPInformationError.unavailable }
        return try await load.value
    }
    nonisolated func tracerouteProvider() -> TracerouteIPInformationProvider {
        TracerouteIPInformationProvider(currentVersion: {
            guard let service = try? await self.service() else { return nil }
            return await service.currentVersion()
        }, lookup: { address, version in
            let service = try await self.service()
            return try await service.tracerouteProvider().lookup(address, version)
        })
    }
}

@MainActor
struct IPInformationSettingsShell: View {
    @ObservedObject var owner: IPInformationAppOwner
    var onDatabaseChanged: @MainActor @Sendable () -> Void = {}
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    var body: some View {
        switch owner.phase {
        case .loading:
            ProgressView(zh ? "正在载入数据库…" : "Loading databases…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label(zh ? "无法载入数据库" : "Databases unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(zh ? "未开始下载，请重试。" : "No download was started. Try again.")
            } actions: {
                Button(zh ? "重试" : "Retry") { owner.retry() }
            }
        case .ready(let service):
            IPInformationDatabaseView(service: service, onDatabaseChanged: onDatabaseChanged)
        }
    }
}

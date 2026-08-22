#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeLocalModels

@MainActor
final class LocalModelsCenter: ObservableObject {
    enum RuntimeState: Equatable {
        case unloaded
        case loading(String)
        case ready(String)
        case failed(String, String)
    }
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var activeDownloads: Set<String> = []
    @Published private(set) var pausedDownloads: Set<String> = []
    @Published private(set) var downloadProgress: [String: LocalModelDownloadProgress] = [:]
    @Published private(set) var runtimeState: RuntimeState = .unloaded
    @Published var errorMessage: String?
    let store: LocalModelStore
    let runtime: LocalModelRuntime
    var onCatalogChanged: (@Sendable () async -> Void)?
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(store: LocalModelStore, runtime: LocalModelRuntime) {
        self.store = store
        self.runtime = runtime
        Task { await refresh() }
    }

    func prepareForTask(modelID: String, includesVisionProjector: Bool = false) async throws {
        runtimeState = .loading(modelID)
        do {
            try await runtime.preload(
                modelID: modelID,
                includesVisionProjector: includesVisionProjector
            )
            runtimeState = .ready(modelID)
        } catch {
            runtimeState = .failed(modelID, error.localizedDescription)
            throw error
        }
    }

    func load(_ entry: LocalModelCatalogEntry) {
        guard installedIDs.contains(entry.id) else { return }
        Task {
            do { try await prepareForTask(modelID: entry.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func unload(_ entry: LocalModelCatalogEntry) {
        Task {
            await runtime.unload(modelID: entry.id)
            runtimeState = .unloaded
        }
    }

    func refresh() async {
        var installed = Set<String>()
        for entry in CuratedLocalModelCatalog.entries where await store.isInstalled(id: entry.id) {
            installed.insert(entry.id)
        }
        installedIDs = installed
        let resumable = await store.resumableModelIDs()
        pausedDownloads.formUnion(resumable.subtracting(activeDownloads))
        FloeLogger(category: .providers).debug(
            "localModelCatalogRefreshed installed=\(installed.count) activeDownloads=\(activeDownloads.count)"
        )
    }

    func download(_ entry: LocalModelCatalogEntry) {
        guard !activeDownloads.contains(entry.id) else { return }
        pausedDownloads.remove(entry.id)
        activeDownloads.insert(entry.id)
        errorMessage = nil
        FloeLogger(category: .providers).info("localModelDownloadRequested model=\(entry.id)")
        downloadTasks[entry.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.store.download(entry) { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress[entry.id] = progress }
                }
                await self.refresh()
                await self.onCatalogChanged?()
            }
            catch {
                if self.pausedDownloads.contains(entry.id) || Task.isCancelled {
                    self.activeDownloads.remove(entry.id)
                    return
                }
                let nsError = error as NSError
                FloeLogger(category: .providers).warning(
                    "localModelDownloadUIFailed model=\(entry.id) domain=\(nsError.domain) code=\(nsError.code)"
                )
                self.errorMessage = error.localizedDescription
            }
            self.activeDownloads.remove(entry.id)
            self.downloadTasks[entry.id] = nil
        }
    }

    func pause(_ entry: LocalModelCatalogEntry) {
        guard activeDownloads.contains(entry.id) else { return }
        pausedDownloads.insert(entry.id)
        Task { await store.pauseDownload(id: entry.id) }
        activeDownloads.remove(entry.id)
    }

    func cancel(_ entry: LocalModelCatalogEntry) {
        pausedDownloads.remove(entry.id)
        activeDownloads.remove(entry.id)
        downloadProgress[entry.id] = nil
        downloadTasks[entry.id]?.cancel()
        downloadTasks[entry.id] = nil
        Task { await store.cancelDownload(id: entry.id) }
    }

    func remove(_ entry: LocalModelCatalogEntry) {
        FloeLogger(category: .providers).info("localModelRemovalRequested model=\(entry.id)")
        Task {
            do {
                try await store.remove(id: entry.id)
                await refresh()
                await onCatalogChanged?()
            }
            catch {
                let nsError = error as NSError
                FloeLogger(category: .providers).warning(
                    "localModelRemovalFailed model=\(entry.id) domain=\(nsError.domain) code=\(nsError.code)"
                )
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct LocalModelsSettingsView: View {
    @ObservedObject var center: LocalModelsCenter

    var body: some View {
        List {
            Section {
                ForEach(CuratedLocalModelCatalog.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName).font(.headline)
                                Text("\(entry.parameterBillions, specifier: "%.1f")B · \(entry.license)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if center.activeDownloads.contains(entry.id) {
                                Button("localmodels.pause") { center.pause(entry) }
                            } else if center.pausedDownloads.contains(entry.id) {
                                Button("localmodels.resume") { center.download(entry) }
                                Button("localmodels.cancel", role: .destructive) { center.cancel(entry) }
                            } else if center.installedIDs.contains(entry.id) {
                                switch center.runtimeState {
                                case .loading(let id) where id == entry.id:
                                    ProgressView().controlSize(.small)
                                    Text("正在加载…").font(.caption).foregroundStyle(.secondary)
                                case .ready(let id) where id == entry.id:
                                    Button("卸载") { center.unload(entry) }
                                default:
                                    Button("加载") { center.load(entry) }
                                }
                                Button("localmodels.remove", role: .destructive) { center.remove(entry) }
                            } else {
                                Button("localmodels.download") { center.download(entry) }
                            }
                        }
                        if let progress = center.downloadProgress[entry.id],
                           center.activeDownloads.contains(entry.id) || center.pausedDownloads.contains(entry.id) {
                            ProgressView(value: progress.fractionCompleted) {
                                Text(progress.component == "projector" ? "localmodels.projector" : "localmodels.weights")
                            } currentValueLabel: {
                                Text(Self.progressLabel(progress))
                            }
                        }
                        HStack(spacing: 12) {
                            if entry.supportsVision { Label("localmodels.vision", systemImage: "eye") }
                            if entry.supportsReasoning { Label("localmodels.reasoning", systemImage: "brain") }
                            if entry.supportsToolCalling { Label("localmodels.tools", systemImage: "wrench.and.screwdriver") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if case .failed(let id, let message) = center.runtimeState, id == entry.id {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    }.padding(.vertical, 4)
                }
            } footer: {
                Text("localmodels.footer")
            }
            if let errorMessage = center.errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("localmodels.title")
        .task { await center.refresh() }
    }

    private static func progressLabel(_ progress: LocalModelDownloadProgress) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: progress.bytesReceived)
        if let expected = progress.bytesExpected {
            var parts = [
                "\(Int(progress.fractionCompleted * 100))%",
                "\(received) / \(formatter.string(fromByteCount: expected))"
            ]
            if let speed = progress.bytesPerSecond, speed > 0 {
                parts.append("\(formatter.string(fromByteCount: Int64(speed)))/s")
            }
            if let remaining = progress.estimatedRemainingSeconds, remaining.isFinite {
                let durationFormatter = DateComponentsFormatter()
                durationFormatter.unitsStyle = .abbreviated
                durationFormatter.allowedUnits = remaining >= 3_600 ? [.hour, .minute] : [.minute, .second]
                parts.append(durationFormatter.string(from: remaining) ?? "")
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return received
    }
}
#endif

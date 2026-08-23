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
    @Published private(set) var incompatibleReasons: [String: String] = [:]
    @Published private(set) var removingIDs: Set<String> = []
    @Published private(set) var benchmarkingIDs: Set<String> = []
    @Published private(set) var benchmarkResults: [String: LocalModelBenchmarkResult] = [:]
    @Published private(set) var appleFoundationAvailability: AppleFoundationModelAvailability = .unsupportedOS
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
        FloeLogger(category: .providers).info(
            "localModelLoadRequested model=\(entry.id) installedSnapshot=\(installedIDs.contains(entry.id))"
        )
        Task {
            guard await store.isInstalled(id: entry.id) else {
                await refresh()
                errorMessage = "本地模型文件不完整或已被移除，请重新下载。"
                FloeLogger(category: .providers).warning(
                    "localModelLoadRejected model=\(entry.id) reason=inventoryMismatch"
                )
                return
            }
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

    func benchmark(_ entry: LocalModelCatalogEntry) {
        guard installedIDs.contains(entry.id), !benchmarkingIDs.contains(entry.id) else { return }
        benchmarkingIDs.insert(entry.id)
        errorMessage = nil
        Task {
            do {
                runtimeState = .loading(entry.id)
                let result = try await runtime.benchmark(modelID: entry.id)
                benchmarkResults[entry.id] = result
                runtimeState = .ready(entry.id)
                FloeLogger(category: .providers).info(
                    "localModelBenchmarkFinished model=\(entry.id) outputTokens=\(result.outputTokens) durationMs=\(result.totalDurationMs) ttftMs=\(result.timeToFirstTokenMs ?? -1) tokensPerSecond=\(result.tokensPerSecond ?? -1) recommendedConcurrency=\(result.recommendedConcurrentTasks)"
                )
            } catch {
                runtimeState = .failed(entry.id, error.localizedDescription)
                errorMessage = error.localizedDescription
            }
            benchmarkingIDs.remove(entry.id)
        }
    }

    func refresh() async {
        appleFoundationAvailability = await AppleFoundationModelRuntime.shared.availability()
        var installed = Set<String>()
        var incompatible: [String: String] = [:]
        let availableBytes = LocalInferenceResourcePolicy.availableMemoryBytes()
        for entry in CuratedLocalModelCatalog.knownEntries where await store.isInstalled(id: entry.id) {
            installed.insert(entry.id)
            if let mappedBytes = await store.installedWeightBytes(id: entry.id),
               !LocalInferenceResourcePolicy.canLoad(
                mappedBytes: mappedBytes,
                physicalMemoryBytes: availableBytes
               ) {
                incompatible[entry.id] = Self.incompatibleMessage(
                    mappedBytes: mappedBytes,
                    availableBytes: availableBytes
                )
            }
        }
        installedIDs = installed
        incompatibleReasons = incompatible
        let resumable = await store.resumableModelIDs()
        pausedDownloads.formUnion(resumable.subtracting(activeDownloads))
        FloeLogger(category: .providers).debug(
            "localModelCatalogRefreshed installed=\(installed.count) activeDownloads=\(activeDownloads.count)"
        )
    }

    private static func incompatibleMessage(mappedBytes: UInt64, availableBytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return "当前可用内存不足：模型权重 \(formatter.string(fromByteCount: Int64(mappedBytes)))，进程可用 \(formatter.string(fromByteCount: Int64(availableBytes)))。关闭大型 App 后刷新，或选更小模型。"
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
        guard !removingIDs.contains(entry.id) else { return }
        FloeLogger(category: .providers).info("localModelRemovalRequested model=\(entry.id)")
        // Reflect the destructive choice immediately. Reopening Settings must
        // never be required to observe a completed deletion.
        removingIDs.insert(entry.id)
        installedIDs.remove(entry.id)
        incompatibleReasons[entry.id] = nil
        downloadProgress[entry.id] = nil
        Task {
            do {
                await runtime.unload(modelID: entry.id)
                if case .ready(let id) = runtimeState, id == entry.id {
                    runtimeState = .unloaded
                }
                try await store.remove(id: entry.id)
                await onCatalogChanged?()
            }
            catch {
                let nsError = error as NSError
                FloeLogger(category: .providers).warning(
                    "localModelRemovalFailed model=\(entry.id) domain=\(nsError.domain) code=\(nsError.code)"
                )
                errorMessage = error.localizedDescription
                await refresh()
            }
            removingIDs.remove(entry.id)
        }
    }
}

struct LocalModelsSettingsView: View {
    @ObservedObject var center: LocalModelsCenter
    @State private var pendingRemoval: LocalModelCatalogEntry?

    var body: some View {
        List {
            if shouldShowAppleFoundationModel {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Foundation Model").font(.headline)
                                Text("由 Apple Intelligence 管理 · 无需下载")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if center.appleFoundationAvailability.isAvailable {
                                Label("可用", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        if case .available(let context, let vision, let tools, let reasoning) =
                            center.appleFoundationAvailability {
                            HStack(spacing: 12) {
                                Label(Self.contextLabel(context), systemImage: "circle.dotted")
                                if vision { Label("视觉", systemImage: "eye") }
                                if tools { Label("工具", systemImage: "wrench.and.screwdriver") }
                                if reasoning { Label("推理", systemImage: "brain") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(AppleFoundationModelRuntime.unavailableMessage(
                                for: center.appleFoundationAvailability
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("系统模型")
                } footer: {
                    Text("可用性由系统实时报告；模型尚在下载时不会循环重试。")
                }
            }
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
                            if center.removingIDs.contains(entry.id) {
                                ProgressView().controlSize(.small)
                                Text("正在删除…").font(.caption).foregroundStyle(.secondary)
                            } else if center.activeDownloads.contains(entry.id) {
                                Button("localmodels.pause") { center.pause(entry) }
                                    .buttonStyle(.borderless)
                            } else if center.pausedDownloads.contains(entry.id) {
                                Button("localmodels.resume") { center.download(entry) }
                                    .buttonStyle(.borderless)
                                Button("localmodels.cancel", role: .destructive) { center.cancel(entry) }
                                    .buttonStyle(.borderless)
                            } else if center.installedIDs.contains(entry.id) {
                                switch center.runtimeState {
                                case .loading(let id) where id == entry.id:
                                    ProgressView().controlSize(.small)
                                    Text("正在加载…").font(.caption).foregroundStyle(.secondary)
                                case .ready(let id) where id == entry.id:
                                    Button("卸载") { center.unload(entry) }
                                        .buttonStyle(.borderless)
                                        .accessibilityIdentifier("localModel.unload.\(entry.id)")
                                default:
                                    Button("加载") { center.load(entry) }
                                        .buttonStyle(.borderless)
                                        .disabled(center.incompatibleReasons[entry.id] != nil)
                                        .accessibilityIdentifier("localModel.load.\(entry.id)")
                                }
                                if center.benchmarkingIDs.contains(entry.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("测速") { center.benchmark(entry) }
                                        .buttonStyle(.borderless)
                                        .disabled(center.incompatibleReasons[entry.id] != nil)
                                        .accessibilityIdentifier("localModel.benchmark.\(entry.id)")
                                }
                                Button("localmodels.remove", role: .destructive) {
                                    FloeLogger(category: .providers).info(
                                        "localModelRemovalConfirmationPresented model=\(entry.id)"
                                    )
                                    pendingRemoval = entry
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("localModel.remove.\(entry.id)")
                            } else {
                                Button("localmodels.download") { center.download(entry) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if let progress = center.downloadProgress[entry.id],
                           center.activeDownloads.contains(entry.id) || center.pausedDownloads.contains(entry.id) {
                            ProgressView(value: progress.fractionCompleted) {
                                Text(progress.component)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
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
                        if let reason = center.incompatibleReasons[entry.id] {
                            Label(reason, systemImage: "memorychip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let result = center.benchmarkResults[entry.id] {
                            Text(Self.benchmarkLabel(result))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            } footer: {
                Text("模型权重不随应用内置；由用户主动下载、固定版本校验并仅保存在本机。MLX 通过 Metal 运行；同一时间只驻留一个模型，多个任务排队复用。")
            }
            let retiredInstalled = CuratedLocalModelCatalog.retiredEntries.filter {
                center.installedIDs.contains($0.id)
            }
            if !retiredInstalled.isEmpty {
                Section("已停用模型") {
                    ForEach(retiredInstalled) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text("该型号已从推荐列表移除，可删除已下载文件。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if center.removingIDs.contains(entry.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("localmodels.remove", role: .destructive) {
                                    pendingRemoval = entry
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            if let errorMessage = center.errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("localmodels.title")
        .task { await center.refresh() }
        .refreshable { await center.refresh() }
        .confirmationDialog(
            "删除本地模型？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = pendingRemoval {
                Button("删除 \(entry.displayName)", role: .destructive) {
                    center.remove(entry)
                    pendingRemoval = nil
                }
            }
            Button("action.cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("删除后需要重新下载模型文件。此操作不会自动恢复。")
        }
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

    private static func benchmarkLabel(_ result: LocalModelBenchmarkResult) -> String {
        let speed = result.tokensPerSecond.map {
            "\($0.formatted(.number.precision(.fractionLength(1)))) token/s"
        } ?? "速度未测得"
        let first = result.timeToFirstTokenMs.map {
            "首 token \((Double($0) / 1_000).formatted(.number.precision(.fractionLength(2))))s"
        } ?? "首 token 未测得"
        return "测速：\(speed) · \(first) · 建议并发 \(result.recommendedConcurrentTasks)"
    }

    private var shouldShowAppleFoundationModel: Bool {
        switch center.appleFoundationAvailability {
        case .unsupportedOS, .unsupportedToolchain:
            return false
        default:
            return true
        }
    }

    private static func contextLabel(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "上下文 \((Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
        }
        return "上下文 \((Double(tokens) / 1_000).formatted(.number.precision(.fractionLength(tokens >= 10_000 ? 0 : 1))))K"
    }
}
#endif

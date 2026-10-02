#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeLocalModels
import FloePersistence

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
    @Published private(set) var enabledRemoteModelIDs: Set<String> = []
    @Published private(set) var hiddenFromPrimaryPickerIDs: Set<String> = []
    @Published var errorMessage: String?
    let store: LocalModelStore
    let runtime: LocalModelRuntime
    let configurationStore: ModelConfigurationStore
    var onCatalogChanged: (@Sendable () async -> Void)?
    var onConfigurationChanged: (@Sendable () async -> Void)?
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(
        store: LocalModelStore,
        runtime: LocalModelRuntime,
        configurationStore: ModelConfigurationStore
    ) {
        self.store = store
        self.runtime = runtime
        self.configurationStore = configurationStore
        Task { await refresh() }
    }

    func isEnabled(remoteModelID: String) -> Bool {
        enabledRemoteModelIDs.contains(remoteModelID)
    }

    func setEnabled(remoteModelID: String, isEnabled: Bool) {
        Task {
            do {
                var configured = try await configurationStore.models(
                    providerID: ProviderProfile.onDeviceProviderID
                )
                if !configured.contains(where: { $0.remoteModelID == remoteModelID }) {
                    await onConfigurationChanged?()
                    configured = try await configurationStore.models(
                        providerID: ProviderProfile.onDeviceProviderID
                    )
                }
                guard var model = configured.first(where: {
                    $0.remoteModelID == remoteModelID
                }) else {
                    throw FloeError.notFound(String(localized: "localmodels.config_not_ready"))
                }
                model.isEnabled = isEnabled
                try await configurationStore.saveModel(model)
                if !isEnabled, remoteModelID != AppleFoundationModelIdentity.remoteModelID {
                    await runtime.unload(modelID: remoteModelID)
                    if case .ready(let id) = runtimeState, id == remoteModelID {
                        runtimeState = .unloaded
                    }
                }
                if !isEnabled {
                    // A disabled model must not stay the persisted default:
                    // Home/Chat would resolve no provider for new tasks even
                    // though other models are enabled. Repair only the broken
                    // default and never touch a running request.
                    try await repairDefaultModelIfNeeded(disabledModelID: model.id, configured: configured)
                }
                await refresh()
                await onConfigurationChanged?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Clears the persisted default only when it points at the model that was
    /// just disabled, choosing the first remaining enabled, primary-visible
    /// chat model. Other surfaces (Home/Chat) reload and see a valid default
    /// instead of an unusable one.
    private func repairDefaultModelIfNeeded(
        disabledModelID: UUID,
        configured: [ModelProfile]
    ) async throws {
        var preferences = try await configurationStore.preferences()
        guard preferences.defaultAgentModelID == disabledModelID else { return }
        let replacement = configured.first(where: {
            $0.id != disabledModelID && $0.isEnabled && $0.isVisibleInPrimaryPicker
                && $0.supportsChatAgentSurface
        })
        preferences.defaultAgentModelID = replacement?.id
        preferences.updatedAt = Date()
        preferences.syncRevision += 1
        try await configurationStore.savePreferences(preferences)
    }

    func isHiddenFromPrimaryPicker(remoteModelID: String) -> Bool {
        hiddenFromPrimaryPickerIDs.contains(remoteModelID)
    }

    func setHiddenFromPrimaryPicker(remoteModelID: String, isHidden: Bool) {
        Task {
            do {
                var configured = try await configurationStore.models(
                    providerID: ProviderProfile.onDeviceProviderID
                )
                if !configured.contains(where: { $0.remoteModelID == remoteModelID }) {
                    await onConfigurationChanged?()
                    configured = try await configurationStore.models(
                        providerID: ProviderProfile.onDeviceProviderID
                    )
                }
                guard var model = configured.first(where: { $0.remoteModelID == remoteModelID }) else {
                    throw FloeError.notFound(String(localized: "localmodels.config_not_ready"))
                }
                model.isHiddenFromPrimaryPicker = isHidden
                try await configurationStore.saveModel(model)

                if isHidden {
                    var preferences = try await configurationStore.preferences()
                    if preferences.defaultAgentModelID == model.id {
                        let visible = configured.first(where: {
                            $0.id != model.id && $0.isEnabled && $0.isVisibleInPrimaryPicker
                        })
                        preferences.defaultAgentModelID = visible?.id
                        preferences.updatedAt = Date()
                        preferences.syncRevision += 1
                        try await configurationStore.savePreferences(preferences)
                    }
                }
                await refresh()
                await onConfigurationChanged?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

    /// Selection-time heavy-runtime interlock for a local MLX model. Runs
    /// before any model-selection persistence, preload, benchmark or chat
    /// call. When Linux guests/services are active it presents the single
    /// app-wide conflict confirmation (through the shared arbiter's decision
    /// handler, never a second modal) describing the affected environments
    /// and services; on confirm the arbiter stops and flushes them, on
    /// cancel it throws and the caller keeps the prior model selection and
    /// the running guests untouched. The preload/benchmark/chat paths still
    /// perform their own arbiter admission afterwards, so a guest that
    /// starts later is caught there instead of being a duplicate prompt here.
    func admitLocalModelSelection(modelID: String) async throws {
        try await runtime.admitLocalModelSelection(modelID: modelID)
    }

    func load(_ entry: LocalModelCatalogEntry) {
        FloeLogger(category: .providers).info(
            "localModelLoadRequested model=\(entry.id) installedSnapshot=\(installedIDs.contains(entry.id))"
        )
        Task {
            guard await store.isInstalled(id: entry.id) else {
                await refresh()
                errorMessage = String(localized: "localmodels.files_incomplete")
                FloeLogger(category: .providers).warning(
                    "localModelLoadRejected model=\(entry.id) reason=inventoryMismatch"
                )
                return
            }
            do {
                // Confirm before any preload when Linux guests/services are
                // active; a cancel keeps the resident model and the guests.
                try await admitLocalModelSelection(modelID: entry.id)
                try await prepareForTask(modelID: entry.id)
            } catch HeavyRuntimeArbiter.ArbiterError.deferredByCaller {
                // User declined at the conflict confirmation: nothing changed.
            } catch {
                errorMessage = error.localizedDescription
            }
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
                // Confirm before any benchmark when Linux guests/services are
                // active; a cancel keeps the resident model and the guests.
                try await admitLocalModelSelection(modelID: entry.id)
                runtimeState = .loading(entry.id)
                let result = try await runtime.benchmark(modelID: entry.id)
                benchmarkResults[entry.id] = result
                runtimeState = .ready(entry.id)
                FloeLogger(category: .providers).info(
                    "localModelBenchmarkFinished model=\(entry.id) outputTokens=\(result.outputTokens) durationMs=\(result.totalDurationMs) ttftMs=\(result.timeToFirstTokenMs ?? -1) tokensPerSecond=\(result.tokensPerSecond ?? -1) recommendedConcurrency=\(result.recommendedConcurrentTasks)"
                )
            } catch HeavyRuntimeArbiter.ArbiterError.deferredByCaller {
                // User declined at the conflict confirmation: nothing changed.
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
        let configuredModels = (try? await configurationStore.models(
            providerID: ProviderProfile.onDeviceProviderID
        )) ?? []
        enabledRemoteModelIDs = Set(configuredModels.filter(\.isEnabled).map(\.remoteModelID))
        hiddenFromPrimaryPickerIDs = Set(configuredModels.filter {
            $0.isHiddenFromPrimaryPicker == true
        }.map(\.remoteModelID))
        let resumable = await store.resumableModelIDs()
        pausedDownloads.formUnion(resumable.subtracting(activeDownloads))
        FloeLogger(category: .providers).debug(
            "localModelCatalogRefreshed installed=\(installed.count) activeDownloads=\(activeDownloads.count)"
        )
    }

    private static func incompatibleMessage(mappedBytes: UInt64, availableBytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let needed = formatter.string(fromByteCount: Int64(mappedBytes))
        let available = formatter.string(fromByteCount: Int64(availableBytes))
        return String.localizedStringWithFormat(
            String(localized: "localmodels.memory_note"),
            needed,
            available
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
            appleFoundationModelSection
            Section {
                ForEach(CuratedLocalModelCatalog.entries, content: curatedEntryRow)
            } header: {
                Label("localmodels.beta_badge", systemImage: "testtube.2")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("localmodels.not_recommended")
                    Text("localmodels.footer")
                }
            }
            let retiredInstalled = CuratedLocalModelCatalog.retiredEntries.filter {
                center.installedIDs.contains($0.id)
            }
            if !retiredInstalled.isEmpty {
                Section {
                    ForEach(retiredInstalled) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text("localmodels.retired_note")
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
                } header: {
                    Text("localmodels.retired_section")
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
            "localmodels.remove_title",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = pendingRemoval {
                Button(
                    String.localizedStringWithFormat(
                        String(localized: "localmodels.remove_button"),
                        entry.displayName
                    ),
                    role: .destructive
                ) {
                    center.remove(entry)
                    pendingRemoval = nil
                }
            }
            Button("action.cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("localmodels.remove_message")
        }
    }

    // Separate sections keep the model list within the Swift expression-checking limit.
    @ViewBuilder
    private func curatedStatusRow(_ entry: LocalModelCatalogEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.headline)
                Text("\(entry.parameterBillions, specifier: "%.1f")B · \(entry.license)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if center.removingIDs.contains(entry.id) {
                ProgressView().controlSize(.small)
                Text("localmodels.removing").font(.caption).foregroundStyle(.secondary)
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
                    Text("localmodels.loading").font(.caption).foregroundStyle(.secondary)
                case .ready(let id) where id == entry.id:
                    Button("action.uninstall") { center.unload(entry) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("localModel.unload.\(entry.id)")
                default:
                    Button("localmodels.load") { center.load(entry) }
                        .buttonStyle(.borderless)
                        .disabled(center.incompatibleReasons[entry.id] != nil)
                        .accessibilityIdentifier("localModel.load.\(entry.id)")
                }
                if center.benchmarkingIDs.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("localmodels.benchmark") { center.benchmark(entry) }
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
    }

    @ViewBuilder
    private func curatedProgressRow(_ entry: LocalModelCatalogEntry) -> some View {
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
    }

    @ViewBuilder
    private func curatedInstalledToggles(_ entry: LocalModelCatalogEntry) -> some View {
        if center.installedIDs.contains(entry.id) {
            Toggle("model.enabled", isOn: Binding(
                get: { center.isEnabled(remoteModelID: entry.id) },
                set: { center.setEnabled(remoteModelID: entry.id, isEnabled: $0) }
            ))
            .tint(FloeTheme.primary)
            .accessibilityIdentifier("localModel.enabled.\(entry.id)")
            Toggle("model.hide_from_primary_picker", isOn: Binding(
                get: { center.isHiddenFromPrimaryPicker(remoteModelID: entry.id) },
                set: {
                    center.setHiddenFromPrimaryPicker(
                        remoteModelID: entry.id,
                        isHidden: $0
                    )
                }
            ))
            .tint(FloeTheme.primary)
            .accessibilityIdentifier("localModel.hideFromPrimaryPicker.\(entry.id)")
        }
    }

    @ViewBuilder
    private var appleFoundationModelSection: some View {
        if shouldShowAppleFoundationModel {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    appleFoundationModelStatusRow
                    Toggle("model.hide_from_primary_picker", isOn: Binding(
                        get: {
                            center.isHiddenFromPrimaryPicker(
                                remoteModelID: AppleFoundationModelIdentity.remoteModelID
                            )
                        },
                        set: {
                            center.setHiddenFromPrimaryPicker(
                                remoteModelID: AppleFoundationModelIdentity.remoteModelID,
                                isHidden: $0
                            )
                        }
                    ))
                    .accessibilityIdentifier("localModel.hideFromPrimaryPicker.appleFoundation")
                    if case .available(let context, let vision, let tools, let reasoning) =
                        center.appleFoundationAvailability {
                        HStack(spacing: 12) {
                            Label(Self.contextLabel(context), systemImage: "circle.dotted")
                            if vision { Label("localmodels.vision", systemImage: "eye") }
                            if tools { Label("localmodels.tools", systemImage: "wrench.and.screwdriver") }
                            if reasoning { Label("localmodels.reasoning", systemImage: "brain") }
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
                Text("localmodels.system_section")
            } footer: {
                Text("localmodels.apple_footer")
            }
        }
    }

    @ViewBuilder
    private var appleFoundationModelStatusRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Foundation Model").font(.headline)
                Text("localmodels.apple_subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("model.enabled", isOn: Binding(
                get: {
                    center.isEnabled(
                        remoteModelID: AppleFoundationModelIdentity.remoteModelID
                    )
                },
                set: {
                    center.setEnabled(
                        remoteModelID: AppleFoundationModelIdentity.remoteModelID,
                        isEnabled: $0
                    )
                }
            ))
            .labelsHidden()
            .accessibilityIdentifier("localModel.enabled.appleFoundation")
            if center.appleFoundationAvailability.isAvailable {
                Label("localmodels.available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func curatedEntryRow(_ entry: LocalModelCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            curatedStatusRow(entry)
            curatedProgressRow(entry)
            HStack(spacing: 12) {
                if entry.supportsVision { Label("localmodels.vision", systemImage: "eye") }
                if entry.supportsReasoning { Label("localmodels.reasoning", systemImage: "brain") }
                if entry.supportsToolCalling { Label("localmodels.tools", systemImage: "wrench.and.screwdriver") }
            }.font(.caption).foregroundStyle(.secondary)
            curatedInstalledToggles(entry)
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
            String.localizedStringWithFormat(
                String(localized: "localmodels.tokens_per_second"),
                $0.formatted(.number.precision(.fractionLength(1)))
            )
        } ?? String(localized: "localmodels.speed_unmeasured")
        let first: String
        if let ms = result.timeToFirstTokenMs {
            first = String.localizedStringWithFormat(
                String(localized: "localmodels.first_reply"),
                (Double(ms) / 1_000).formatted(.number.precision(.fractionLength(2)))
            )
        } else {
            first = String(localized: "localmodels.first_reply_unmeasured")
        }
        return String.localizedStringWithFormat(
            String(localized: "localmodels.benchmark_summary"),
            speed,
            first,
            Int64(result.recommendedConcurrentTasks)
        )
    }

    private var shouldShowAppleFoundationModel: Bool {
        // Keep the row visible even when the system model cannot run. The
        // availability reason is the actionable setting: hiding it made a
        // selected Apple Intelligence model look like a missing local model.
        return true
    }

    private static func contextLabel(_ tokens: Int) -> String {
        let value: String
        if tokens >= 1_000_000 {
            value = (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + "M"
        } else {
            value = (Double(tokens) / 1_000).formatted(
                .number.precision(.fractionLength(tokens >= 10_000 ? 0 : 1))
            ) + "K"
        }
        return String.localizedStringWithFormat(
            String(localized: "localmodels.context"),
            value
        )
    }
}
#endif

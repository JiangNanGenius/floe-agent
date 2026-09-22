// FloeApp — Execution environment settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 5: JS probe (real), local
// Python/Node (Linux guest component with honest install state), remote
// Python, remote terminal counts, and the persisted execution preferences.
// Unavailable capabilities are greyed out, never faked.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeSSH

struct ExecutionEnvironmentView: View {
    @ObservedObject var center: SettingsCenter

    /// Deep links from a Linux session/service notification focus one
    /// environment instead of whichever Linux environment happens to be first.
    var initialEnvironmentID: String? = nil

    /// Explicit Linux component state for the top-level execution screen: the
    /// same App-shared install job the environment manager and the terminal
    /// empty state use, so a first-use download here is shared, cancellable
    /// and retryable rather than a second implementation.
    @State private var linuxImageModel: LinuxImageInstallModel?
    @State private var linuxImageStatus: LinuxGuestImageInstallationService.ImageStatus?
    @State private var linuxEnvironmentID: String?
    @State private var linuxEnvironmentTitle = "Linux 环境"
    @State private var linuxGuestStatus: LinuxGuestStatus?
    @State private var linuxBusy = false
    @State private var linuxError: String?
    @State private var linuxUpdateNotice: String?
    /// Shared background-work record for the Linux session (state + the
    /// bounded metrics sample). Read from the app-wide registry so this screen
    /// shows the same numbers as notifications and the status surface.
    @State private var linuxBackgroundWork: BackgroundWorkSnapshot?
    @State private var activeServiceCount: Int?

    var body: some View {
        Form {
            Section("settings.exec.linux.section") {
                linuxComponentSection
            }

            if let environmentID = linuxEnvironmentID, linuxGuestStatus?.running == true {
                linuxBackgroundSection(environmentID: environmentID)
            }

            Section("settings.exec.runtimes") {
                if center.runtimeInventory.isEmpty {
                    Text("settings.exec.runtimes.empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(center.runtimeInventory) { entry in
                    runtimeRow(entry)
                }
                LabeledContent("settings.exec.remote_terminal") {
                    Text(String.localizedStringWithFormat(
                        String(localized: "settings.exec.remote_terminal.value"),
                        center.remoteHostCount,
                        center.activeRemoteSessionCount
                    ))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section("settings.exec.packages") {
                NavigationLink {
                    EnvironmentManagerView(ownerTitles: Dictionary(uniqueKeysWithValues:
                        center.environment.conversationCenter.conversations.map { ($0.id.uuidString, $0.title) }
                    ))
                } label: {
                    Label("environment.manager.entry", systemImage: "shippingbox")
                }
                Text("查看每层依赖与容量，安装或卸载软件包，停止、恢复环境和保存模板。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("settings.exec.defaults") {
                Picker("settings.exec.target", selection: Binding(
                    get: { center.execution.target },
                    set: { newValue in
                        Task { await center.setExecutionTarget(newValue) }
                    }
                )) {
                    Text("settings.exec.target.local").tag(ExecutionTargetPreference.local)
                    ForEach(center.environment.remoteSessionCenter.hosts.filter {
                        $0.isRemoteExecutionEnvironment && $0.hasSSHConnection
                    }) { host in
                        Text(host.displayName).tag(ExecutionTargetPreference.host(host.id))
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                // Hidden: timeout / maxOutputBytes / savesArtifacts are
                // persisted but not yet consumed by any execution path, so
                // the controls are removed until they take real effect.
            }
        }
        .navigationTitle("settings.section.execution")
        .task {
            async let settings: Void = center.load()
            async let hosts: Void = center.environment.remoteSessionCenter.loadHosts()
            async let linux: Void = refreshLinux()
            _ = await (settings, hosts, linux)
        }
        .task(id: linuxEnvironmentID) { await observeLinuxBackgroundWork() }
        .task(id: linuxGuestStatus?.running) { await pollServiceCount() }
    }

    // MARK: - Linux background session (explicit user control)

    /// The user's explicit keep-alive switch plus the bounded, truthful
    /// resource sample. Nothing here claims the guest survives process
    /// termination; the caption says what the system actually does.
    @ViewBuilder
    private func linuxBackgroundSection(environmentID: String) -> some View {
        Section("Linux 后台运行") {
            Toggle("后台保持运行", isOn: backgroundSessionBinding(environmentID: environmentID))
                .frame(minHeight: FloeTheme.minimumTarget)
            Text("开启后，离开 Floe 时系统会用持续处理任务为该环境争取后台时间；应用被系统回收后环境会停止（磁盘保留），重新打开后可再次启动。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("后台任务状态") {
                Text(linuxBackgroundWork?.progressText ?? (center.environment.backgroundRunCoordinator
                    .linuxBackgroundSessionIsEnabled(environmentID: environmentID)
                    ? String(localized: "environment.backend.checking") : "未开启"))
                    .foregroundStyle(.secondary)
            }
            if let work = linuxBackgroundWork {
                LabeledContent("已运行", value: work.elapsedTimeLabel())
                metricsRows(work.metrics)
            }
            LabeledContent("托管服务") {
                Text(activeServiceCount.map(String.init) ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func backgroundSessionBinding(environmentID: String) -> Binding<Bool> {
        let coordinator = center.environment.backgroundRunCoordinator
        return Binding(
            get: { coordinator.linuxBackgroundSessionIsEnabled(environmentID: environmentID) },
            set: { enabled in
                coordinator.setLinuxBackgroundSessionEnabled(
                    enabled,
                    environmentID: environmentID,
                    title: linuxEnvironmentTitle
                )
            }
        )
    }

    /// Only measured values are shown; a missing sample renders "—", and the
    /// guest GPU is reported unavailable because TinyEMU has no GPU
    /// passthrough (graphics run through native Apple frameworks instead).
    @ViewBuilder
    private func metricsRows(_ metrics: BackgroundWorkMetrics?) -> some View {
        LabeledContent("模拟器 CPU", value: percentText(metrics?.emulatorCPUFraction))
        LabeledContent("客户机 CPU", value: percentText(metrics?.guestCPUFraction))
        LabeledContent("客户机内存", value: memoryText(metrics))
        LabeledContent("网络流量", value: networkText(metrics))
        LabeledContent("GPU") {
            Text("不可用（TinyEMU 无 GPU 直通；图形使用原生框架）")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.0f%%", min(1, max(0, fraction)) * 100)
    }

    private func memoryText(_ metrics: BackgroundWorkMetrics?) -> String {
        guard let used = metrics?.guestMemoryUsedMB, let total = metrics?.guestMemoryTotalMB else {
            return "—"
        }
        return "\(used) / \(total) MB"
    }

    private func networkText(_ metrics: BackgroundWorkMetrics?) -> String {
        guard let rx = metrics?.networkRxKB, let tx = metrics?.networkTxKB else { return "—" }
        return String(format: "↓ %.0f KB · ↑ %.0f KB", rx, tx)
    }

    /// A Linux guest only outlives the screen when the user asked for it, so
    /// the work record is only sampled while the switch is on.
    private func observeLinuxBackgroundWork() async {
        guard let environmentID = linuxEnvironmentID else {
            linuxBackgroundWork = nil
            return
        }
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        for await snapshots in await BackgroundWorkRegistry.shared.snapshots() {
            if Task.isCancelled { return }
            linuxBackgroundWork = snapshots.first { $0.id == workID }
        }
    }

    private func pollServiceCount() async {
        guard linuxGuestStatus?.running == true, let environmentID = linuxEnvironmentID else {
            activeServiceCount = nil
            return
        }
        let controller = FloePlatformServices.shared.linuxLocalServiceController()
        while !Task.isCancelled {
            activeServiceCount = await controller?.activeLocalServiceCount(
                environmentID: environmentID
            )
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    // MARK: - Linux component (download / update / start)

    @ViewBuilder
    private var linuxComponentSection: some View {
        if !FloePlatformServices.shared.linuxGuestImageStorageAvailable() {
            Text("environment.backend.image_store_unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            if let model = linuxImageModel {
                LinuxImageInstallCard(model: model) {
                    // A finished install is exactly the first-use moment:
                    // start the environment so the component is usable, but
                    // do not hide a start failure behind the download result.
                    await startLinuxEnvironment()
                }
            }
            if let status = linuxImageStatus {
                LabeledContent("environment.backend.image", value: status.id)
                if status.installed, status.verificationFailure == nil {
                    Label("environment.backend.status.running", systemImage: "checkmark.seal")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.success)
                } else if let failure = status.verificationFailure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(FloeTheme.destructive)
                        .textSelection(.enabled)
                }
            }
            if let update = linuxUpdateNotice {
                Label(update, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.pending)
            }
            if let environmentID = linuxEnvironmentID, let status = linuxGuestStatus {
                LabeledContent("environment.backend.status", value: status.running
                    ? String(localized: "environment.backend.status.running")
                    : String(localized: "environment.backend.status.stopped"))
                if status.running {
                    if let network = status.networkStatus {
                        LabeledContent("environment.backend.network", value: networkLabel(network))
                    }
                    if let message = status.lastError, status.networkStatus?.isReady != true {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(FloeTheme.pending)
                            .textSelection(.enabled)
                    }
                    Button("environment.backend.stop", systemImage: "stop") {
                        Task { await stopLinuxEnvironment(id: environmentID) }
                    }
                    .disabled(linuxBusy)
                } else {
                    Button("environment.backend.start", systemImage: "play") {
                        Task { await startLinuxEnvironment() }
                    }
                    .disabled(linuxBusy || status.imageInstalled == false || status.imageVerificationFailure != nil)
                }
            } else {
                Text("settings.exec.linux.start_hint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if linuxBusy { ProgressView("environment.backend.checking") }
            if let linuxError {
                Label(linuxError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .textSelection(.enabled)
            }
            // The per-environment manager entry lives in the packages section
            // below; this section only owns the shared component and the
            // first start, so the screen does not grow a second identical link.
        }
    }

    private func networkLabel(_ status: LinuxGuestNetworkStatus) -> String {
        switch status {
        case .up: return String(localized: "environment.backend.network.up")
        case .partial: return String(localized: "environment.backend.network.partial")
        case .down: return String(localized: "environment.backend.network.down")
        }
    }

    /// Reads the App-shared image state, finds the first Linux environment and
    /// reports the real guest state. No state is invented when the service is
    /// unavailable.
    private func refreshLinux() async {
        guard FloePlatformServices.shared.linuxGuestImageStorageAvailable() else { return }
        let imageID = LinuxGuestImageDistributionCatalog.defaultImageID
        if linuxImageModel == nil {
            linuxImageModel = LinuxImageInstallModel(imageID: imageID)
        }
        await linuxImageModel?.probeOnce()
        linuxImageStatus = await FloePlatformServices.shared.linuxImageStatus(id: imageID)
        linuxUpdateNotice = await FloePlatformServices.shared.linuxComponentUpdateNeeded(id: imageID)
        guard let reports = try? await FloePlatformServices.shared.environmentReports() else { return }
        let linuxReports = reports.filter {
            $0.record.effectiveExecutionBackend == .linuxVM && $0.record.state != .deleting
        }
        // A notification deep link focuses its own environment; otherwise the
        // first Linux environment is the only honest choice (never a temporary
        // directory or a native fallback).
        let linux = linuxReports.first { $0.id == initialEnvironmentID } ?? linuxReports.first
        linuxEnvironmentID = linux?.id
        if let name = linux?.record.name, !name.isEmpty {
            linuxEnvironmentTitle = name
        }
        linuxGuestStatus = await FloePlatformServices.shared.linuxGuestStatus(id: linux?.id)
    }

    private func startLinuxEnvironment() async {
        guard !linuxBusy else { return }
        linuxBusy = true
        linuxError = nil
        defer { linuxBusy = false }
        do {
            var id = linuxEnvironmentID
            if id == nil {
                let reports = try? await FloePlatformServices.shared.environmentReports()
                id = reports?.first(where: {
                    $0.record.effectiveExecutionBackend == .linuxVM && $0.record.state != .deleting
                })?.id
            }
            guard let id else {
                linuxError = String(localized: "environment.backend.image_missing")
                return
            }
            linuxEnvironmentID = id
            try await FloePlatformServices.shared.activateLinuxGuestWithPreparation(id: id)
            await refreshLinux()
            // A user who already enabled background operation keeps it when
            // the environment starts again: refresh the work record and the
            // system continued-processing request against the live guest.
            if center.environment.backgroundRunCoordinator
                .linuxBackgroundSessionIsEnabled(environmentID: id) {
                center.environment.backgroundRunCoordinator.setLinuxBackgroundSessionEnabled(
                    true,
                    environmentID: id,
                    title: linuxEnvironmentTitle
                )
            }
        } catch {
            linuxError = error.localizedDescription
        }
    }

    private func stopLinuxEnvironment(id: String) async {
        guard !linuxBusy else { return }
        linuxBusy = true
        defer { linuxBusy = false }
        // Stopping the guest ends any background keep-alive with it: leaving
        // the switch on would claim a session that no longer exists.
        center.environment.backgroundRunCoordinator.setLinuxBackgroundSessionEnabled(
            false,
            environmentID: id,
            title: linuxEnvironmentTitle
        )
        await FloePlatformServices.shared.stopLinuxGuest(id: id)
        await refreshLinux()
    }

    private func runtimeRow(_ entry: RuntimeInventoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.displayName)
                Spacer()
                Text(sourceLabel(entry.source))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.primary)
            }
            HStack(spacing: 8) {
                availabilityLabel(entry)
                Spacer()
                updateLabel(entry)
            }
            if let detail = entry.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func availabilityLabel(_ entry: RuntimeInventoryEntry) -> some View {
        switch entry.availability {
        case .available(let version):
            Label(version, systemImage: "checkmark.circle.fill")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.success)
        case .notInstalled:
            Label("settings.exec.runtime.not_installed", systemImage: "circle.dashed")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
        case .unavailable(let reason):
            Label(reason, systemImage: "minus.circle")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func updateLabel(_ entry: RuntimeInventoryEntry) -> some View {
        switch entry.update {
        case .current:
            Text("settings.exec.runtime.update.current")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        case .installable(let version):
            Text(String.localizedStringWithFormat(
                String(localized: "settings.exec.runtime.update.installable"), version
            ))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.primary)
        case .updatable(_, let available):
            Text(String.localizedStringWithFormat(
                String(localized: "settings.exec.runtime.update.updatable"), available
            ))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
        case .unavailable:
            EmptyView()
        }
    }

    private func sourceLabel(_ source: RuntimeInventoryEntry.Source) -> String {
        switch source {
        case .bundled: return String(localized: "settings.exec.runtime.source.bundled")
        case .user: return String(localized: "settings.exec.runtime.source.user")
        case .project: return String(localized: "settings.exec.runtime.source.project")
        case .remote: return String(localized: "settings.exec.runtime.source.remote")
        case .component: return String(localized: "settings.exec.runtime.source.component")
        }
    }
}
#endif

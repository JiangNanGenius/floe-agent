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

    /// Explicit Linux component state for the top-level execution screen: the
    /// same App-shared install job the environment manager and the terminal
    /// empty state use, so a first-use download here is shared, cancellable
    /// and retryable rather than a second implementation.
    @State private var linuxImageModel: LinuxImageInstallModel? = LinuxImageInstallModel(imageID: LinuxGuestImageDistributionCatalog.defaultImageID)
    @State private var linuxImageStatus: LinuxGuestImageInstallationService.ImageStatus?
    @State private var linuxEnvironmentID: String?
    @State private var linuxGuestStatus: LinuxGuestStatus?
    @State private var linuxBusy = false
    @State private var linuxError: String?
    @State private var linuxUpdateNotice: String?

    var body: some View {
        Form {
            Section("settings.exec.linux.section") {
                linuxComponentSection
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
    }

    // MARK: - Linux component (download / update / start)

    @ViewBuilder
    private var linuxComponentSection: some View {
        if !FloePlatformServices.shared.linuxGuestImageStorageAvailable() {
            Text("environment.backend.image_store_unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            // One card derives the single authoritative state: a verified
            // installed/running component never renders the download entry.
            if let model = linuxImageModel {
                LinuxImageInstallCard(model: model) {
                    // A finished install is exactly the first-use moment:
                    // start the environment, but never hide a start failure.
                    await startLinuxEnvironment()
                }
            }
            if let environmentID = linuxEnvironmentID, let status = linuxGuestStatus, status.running {
                LabeledContent("environment.backend.status", value: String(localized: "environment.backend.status.running"))
                if let network = status.networkStatus {
                    LabeledContent("environment.backend.network", value: networkLabel(network))
                }
                if let resize = status.diskResizeFailure {
                    Label(resize, systemImage: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(FloeTheme.pending)
                        .textSelection(.enabled)
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
            }
            if linuxBusy { ProgressView("environment.backend.checking") }
            if let linuxError {
                Label(linuxError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .textSelection(.enabled)
            }
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
        let linux = try? await FloePlatformServices.shared.environmentReports().first { $0.record.effectiveExecutionBackend == .linuxVM && $0.record.state != .deleting }
        linuxEnvironmentID = linux?.id
        linuxGuestStatus = await FloePlatformServices.shared.linuxGuestStatus(id: linux?.id)
        await linuxImageModel?.refresh(environmentIDHint: linux?.id)
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
        } catch {
            linuxError = error.localizedDescription
        }
    }

    private func stopLinuxEnvironment(id: String) async {
        guard !linuxBusy else { return }
        linuxBusy = true
        defer { linuxBusy = false }
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

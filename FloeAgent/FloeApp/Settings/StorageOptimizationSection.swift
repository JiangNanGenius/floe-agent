#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct StorageOptimizationSection: View {
    @ObservedObject var service: StorageOptimizationService
    @State private var showsDetails = false

    var body: some View {
        Section {
            Button { service.start() } label: {
                Label(FloeL10n.l("settings.storage_optimization.start"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(!service.canStart)

            HStack {
                if service.isRunning { ProgressView().controlSize(.small) }
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            if let fraction = service.state.fraction, service.isRunning {
                ProgressView(value: fraction)
            }
            if service.isRunning {
                Button(FloeL10n.l("settings.storage_optimization.cancel"), role: .cancel) {
                    service.cancel()
                }.disabled(!service.canCancel)
            }

            if service.state.attempted > 0 || !service.state.details.isEmpty {
                DisclosureGroup(isExpanded: $showsDetails) {
                    metric("settings.storage_optimization.optimized", value: String(service.state.optimized))
                    metric("settings.storage_optimization.skipped", value: String(service.state.skipped))
                    let remaining = max(0, service.state.total - service.state.optimized - service.state.skipped)
                    if remaining > 0 { metric("settings.storage_optimization.remaining", value: String(remaining)) }
                    if let delta = service.state.observedHostFreeDelta {
                        metric("settings.storage_optimization.host_free_change", value: signedBytes(delta))
                        Text(FloeL10n.l("settings.storage_optimization.host_change_note"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    metric("settings.storage_optimization.file_allocation_change",
                           value: ByteCountFormatter.string(fromByteCount: service.state.fileAllocationReduction, countStyle: .file))
                    Text(FloeL10n.l("settings.storage_optimization.file_change_note"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(FloeL10n.l("settings.storage_optimization.guest_unchanged"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(service.state.details.keys.sorted(), id: \.self) { code in
                        HStack {
                            Text(code).font(.caption.monospaced())
                            Spacer()
                            Text(String(service.state.details[code] ?? 0)).font(.caption).monospacedDigit()
                        }.foregroundStyle(.secondary)
                    }
                } label: {
                    Text(FloeL10n.l("settings.storage_optimization.details"))
                }
            }
        } header: {
            Text(FloeL10n.l("settings.storage_optimization.title"))
        } footer: {
            Text(FloeL10n.l("settings.storage_optimization.keeps_data"))
        }
    }

    private var status: String {
        switch service.state.phase {
        case .idle: return FloeL10n.l("settings.storage_optimization.ready")
        case .checking: return FloeL10n.l("settings.storage_optimization.checking")
        case .optimizing:
            return FloeL10n.l("settings.storage_optimization.progress", service.state.attempted, service.state.total)
        case .cancelling: return FloeL10n.l("settings.storage_optimization.stopping")
        case .completed:
            return service.state.optimized == 0
                ? FloeL10n.l("settings.storage_optimization.no_change")
                : FloeL10n.l("settings.storage_optimization.done", service.state.optimized)
        case .cancelled: return FloeL10n.l("settings.storage_optimization.cancelled")
        case .blocked: return service.state.inventoryNotice ?? FloeL10n.l("settings.storage_optimization.try_later")
        case .unavailable:
            return FloeL10n.l(service.hasLegacyRecoveryTree
                ? "settings.storage_optimization.try_later" : "settings.storage_optimization.no_change")
        }
    }
    private func metric(_ key: String, value: String) -> some View {
        HStack {
            Text(FloeL10n.l(key))
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }.font(.caption)
    }
    private func signedBytes(_ value: Int64) -> String {
        let magnitude = value == Int64.min ? Int64.max : abs(value)
        return (value > 0 ? "+" : value < 0 ? "−" : "")
            + ByteCountFormatter.string(fromByteCount: magnitude, countStyle: .file)
    }
}
#endif

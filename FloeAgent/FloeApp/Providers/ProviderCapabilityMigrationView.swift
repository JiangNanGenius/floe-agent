// FloeApp — Reviewed model-capability migration.
//
// The official catalog can carry verified per-model metadata (for example an
// inference model that accepts image input). New models get those defaults at
// creation; models saved before the metadata existed are NEVER rewritten
// silently. This sheet is the single, user-reviewed batch diff: every row
// shows the exact model and the capability it would GAIN, and only an explicit
// "Apply updates" writes anything. Confirmed bits are recorded as explicit
// user decisions, so later refreshes and sync keep them stable.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

struct ProviderCapabilityMigrationView: View {
    let proposals: [ProviderCatalogCapabilityProposal]
    let isApplying: Bool
    let errorMessage: String?
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(proposals) { proposal in
                        proposalRow(proposal)
                    }
                    if let errorMessage, !errorMessage.isEmpty {
                        Text(FloeL10n.l("providers.capability_migration.failed", errorMessage))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.destructive)
                            .accessibilityIdentifier("providers.capability_migration.error")
                    }
                } header: {
                    Text("providers.capability_migration.title")
                } footer: {
                    Text("providers.capability_migration.footer")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("providers.capability_migration.title")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isApplying)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("providers.capability_migration.not_now") { dismiss() }
                        .disabled(isApplying)
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("providers.capability_migration.not_now")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply()
                    } label: {
                        if isApplying {
                            ProgressView()
                                .accessibilityLabel(Text("providers.capability_migration.applying"))
                        } else {
                            Text("providers.capability_migration.apply")
                        }
                    }
                    .disabled(isApplying || proposals.isEmpty)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("providers.capability_migration.apply")
                }
            }
        }
    }

    private func proposalRow(_ proposal: ProviderCatalogCapabilityProposal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(proposal.providerName)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Text(proposal.displayName)
                .font(FloeTheme.Typography.body)
            Text(proposal.remoteModelID)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Per-model before/after so the user confirms the actual change,
            // never a summarized batch.
            Text(FloeL10n.l(
                "providers.capability_migration.before",
                Self.capabilityNames(proposal.currentCapabilities)
            ))
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
            Text(FloeL10n.l(
                "providers.capability_migration.after",
                Self.capabilityNames(proposal.currentCapabilities.union(proposal.addedCapabilities))
            ))
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(FloeTheme.primary)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("providers.capability_migration.row.\(proposal.remoteModelID)")
    }

    /// Localized capability names for the review diff. Reuses the existing
    /// model-editor keys; the migration only ever adds bits to inference
    /// models, so vision is the realistic entry.
    static func capabilityNames(_ capabilities: ModelCapabilities) -> String {
        var names: [String] = []
        if capabilities.contains(.text) { names.append(FloeL10n.l("model.capability.text")) }
        if capabilities.contains(.vision) { names.append(FloeL10n.l("model.capability.vision")) }
        if capabilities.contains(.tools) { names.append(FloeL10n.l("model.capability.tools")) }
        if capabilities.contains(.imageGeneration) { names.append(FloeL10n.l("auxiliary.generation")) }
        if capabilities.contains(.imageEditing) { names.append(FloeL10n.l("auxiliary.editing")) }
        if capabilities.contains(.videoGeneration) {
            names.append(FloeL10n.l("core.canvas_operations.video_generation"))
        }
        let separator = FloeL10n.isChinese ? "、" : ", "
        return names.joined(separator: separator)
    }
}
#endif

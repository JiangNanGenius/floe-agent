// FloeApp — Trusted work-mode (工况) section for the design owner sheet.
//
// Shows the FROZEN work mode for this design target's task and hosts the
// 重构 preservation confirmation. The mode itself is trusted data: it is
// frozen at launch (DesignLaunchBinding) and design tools read it back, so
// the model can never downgrade an active restructure by omitting a field.
// Confirming a restructure mints the single-use grant through
// DesignRestructureAuthorization and upgrades the durable binding BEFORE any
// mutation can run.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct DesignWorkModeSection: View {
    @ObservedObject var model: DesignOwnerWorkflowModel
    /// Fresh bindings reload on appear; the section also refreshes after a
    /// successful confirmation through the model's published property.
    @State private var restructureExpanded = false
    @State private var contentEntries: [String] = []
    @State private var dataEntries: [String] = []
    @State private var behaviorEntries: [String] = []
    @State private var formatEntries: [String] = []
    @State private var confirmError: String?

    private var binding: DesignLaunchBinding? { model.workModeBinding }

    var body: some View {
        Section("design.owner.workmode.title") {
            Picker("design.owner.workmode.title", selection: modeSelection) {
                ForEach(availableModes, id: \.self) { mode in
                    Text(label(for: mode)).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("design.owner.workmode.picker")

            if binding?.workMode == .restructure {
                Label("design.owner.restructure.confirmed", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("design.owner.restructure.confirmed")
            }
        }
        // The 重构 confirmation is a separate explicit sheet section: the
        // user must type what must be preserved and confirm; nothing is
        // minted until the button runs.
        if binding?.workMode == .restructure || restructureExpanded {
            Section("design.owner.restructure.requirements") {
                preservationField("design.owner.restructure.content", entries: $contentEntries)
                preservationField("design.owner.restructure.data", entries: $dataEntries)
                preservationField("design.owner.restructure.behavior", entries: $behaviorEntries)
                preservationField("design.owner.restructure.format", entries: $formatEntries)
                if let confirmError {
                    Text(FloeL10n.l(confirmError))
                        .foregroundStyle(FloeTheme.destructive)
                        .accessibilityIdentifier("design.owner.restructure.error")
                }
                Button("design.owner.restructure.confirm") {
                    Task {
                        let error = await model.confirmRestructure(
                            content: contentEntries,
                            data: dataEntries,
                            behavior: behaviorEntries,
                            formatBounds: formatEntries)
                        await MainActor.run {
                            confirmError = error
                            if error == nil {
                                restructureExpanded = false
                                contentEntries = []
                                dataEntries = []
                                behaviorEntries = []
                                formatEntries = []
                            }
                        }
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .disabled(model.busy)
                .accessibilityIdentifier("design.owner.restructure.confirm")
            }
        }
    }

    /// Mode selection: create/modify can be chosen freely (they need no
    /// confirmation); 重构 always routes through the explicit confirmation
    /// section, so picking it here only expands the requirements editor.
    private var modeSelection: Binding<DesignWorkMode?> {
        Binding(
            get: { binding?.workMode ?? .modify },
            set: { newValue in
                guard let newValue else { return }
                if newValue == .restructure {
                    restructureExpanded = true
                } else {
                    restructureExpanded = false
                    confirmError = nil
                    // create/modify need no authority; freeze the simpler mode
                    // by upgrading the binding when a conversation exists.
                    guard let conversationID = model.confirmationOriginConversationID else { return }
                    var updated = binding ?? DesignLaunchBinding(
                        target: model.target, workMode: newValue)
                    updated.workMode = newValue
                    updated.preservation = nil
                    updated.preservationDigest = nil
                    updated.frozenRestructureOperationID = nil
                    try? DesignLaunchBindingStore.save(updated, conversationID: conversationID)
                    model.reloadWorkModeBinding()
                }
            }
        )
    }

    /// 重构 is offered only for targets with real content to reorganize.
    private var availableModes: [DesignWorkMode] {
        if model.currentArtifact == nil { return [.create, .modify] }
        return DesignWorkMode.allCases
    }

    private func label(for mode: DesignWorkMode) -> String {
        FloeL10n.l("design.owner.workmode.\(mode.rawValue)")
    }

    private func preservationField(_ key: String, entries: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(FloeL10n.l(key))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(entries.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(key, text: Binding(
                        get: { entries.wrappedValue[index] },
                        set: { entries.wrappedValue[index] = $0 }
                    ))
                    .autocapitalization(.sentences)
                    Button {
                        entries.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityIdentifier("design.owner.restructure.remove.\(index)")
                }
            }
            Button {
                entries.wrappedValue.append("")
            } label: {
                Label("design.owner.restructure.add", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("design.owner.restructure.add")
        }
    }
}
#endif

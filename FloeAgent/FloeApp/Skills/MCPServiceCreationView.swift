#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct MCPServiceCreationView: View {
    @ObservedObject var coordinator: MCPServiceCreationCoordinator
    let backend: MCPServiceCreationAppBackend
    let openTask: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var projects: [MCPServiceCreationOption] = []
    @State private var environments: [MCPServiceCreationOption] = []
    @State private var showingNew = false
    @State private var choiceError: String?

    var body: some View {
        NavigationStack {
            Form {
                if showingNew || coordinator.selected == nil {
                    requestFields
                } else if let record = coordinator.selected {
                    operation(record)
                }
                if let error = choiceError ?? coordinator.actionError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if !coordinator.records.isEmpty, !coordinator.isWorking {
                    Section("skills.mcp.creation.recent") {
                        ForEach(coordinator.records) { record in
                            Button {
                                coordinator.select(record.id); showingNew = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.request.name).foregroundStyle(.primary)
                                        Text(LocalizedStringKey(record.phase.titleKey))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if coordinator.selectedID == record.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("skills.mcp.creation.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.close") {
                        Task { await coordinator.saveDraft() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("skills.mcp.creation.new", systemImage: "plus") { showingNew = true }
                        .disabled(coordinator.isWorking)
                }
            }
            .task {
                await coordinator.load()
                do { projects = try await backend.projectOptions() }
                catch { choiceError = error.localizedDescription }
            }
            .task(id: coordinator.draft.workspaceID) {
                environments = []
                guard let id = coordinator.draft.workspaceID else { return }
                do {
                    environments = try await backend.environmentOptions(workspaceID: id)
                    // No first-environment fallback. Keep a previously chosen
                    // identity only while it remains in this project's set.
                    if let selected = coordinator.draft.environmentID,
                       !environments.contains(where: { $0.id == selected }) {
                        coordinator.draft.environmentID = nil
                    }
                    choiceError = nil
                } catch is CancellationError { }
                catch { choiceError = error.localizedDescription }
            }
            .task(id: coordinator.draft) {
                guard coordinator.isLoaded else { return }
                do { try await Task.sleep(for: .milliseconds(300)); await coordinator.saveDraft() }
                catch is CancellationError { }
                catch { }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await coordinator.saveDraft() } }
            }
            .onDisappear { Task { await coordinator.saveDraft() } }
        }
    }

    private var requestFields: some View {
        Section {
            TextField("skills.mcp.creation.name", text: $coordinator.draft.name)
            Picker("skills.mcp.creation.project", selection: $coordinator.draft.workspaceID) {
                Text("skills.mcp.creation.choose").tag(UUID?.none)
                ForEach(projects) { option in
                    if let id = UUID(uuidString: option.id) { Text(option.title).tag(Optional(id)) }
                }
            }
            Picker("skills.mcp.creation.environment", selection: $coordinator.draft.environmentID) {
                Text("skills.mcp.creation.choose").tag(String?.none)
                ForEach(environments) { Text($0.title).tag(Optional($0.id)) }
            }
            TextField("skills.mcp.creation.port", text: $coordinator.draft.port).keyboardType(.numberPad)
            TextField("skills.mcp.creation.request", text: $coordinator.draft.details, axis: .vertical)
                .lineLimit(5...12)
            Button("skills.mcp.creation.start") {
                Task { await coordinator.startDraft(); if coordinator.selected != nil { showingNew = false } }
            }
            .disabled(!coordinator.isLoaded || coordinator.isWorking || coordinator.draft.workspaceID == nil
                      || coordinator.draft.environmentID == nil || coordinator.draft.details.isEmpty)
            .accessibilityIdentifier("skills.mcp.creation.start")
        }
    }

    @ViewBuilder
    private func operation(_ record: MCPServiceCreationRecord) -> some View {
        Section {
            LabeledContent("skills.mcp.creation.name", value: record.request.name)
            if let binding = record.binding {
                LabeledContent("skills.mcp.creation.model", value: binding.modelName)
            }
            HStack {
                Text(LocalizedStringKey(record.phase == .stopping && !coordinator.isStopping
                    ? "skills.mcp.creation.stop_pending" : record.phase.titleKey))
                Spacer()
                if record.phase.isProcessing && (record.phase != .stopping || coordinator.isStopping) { ProgressView() }
            }
            if record.error != nil { Text("skills.mcp.creation.needs_attention").foregroundStyle(.red) }
            Button("skills.mcp.creation.open_task") {
                Task {
                    do {
                        try await backend.validateTaskLink(record)
                        dismiss(); openTask(record.conversationID)
                    } catch { choiceError = error.localizedDescription }
                }
            }
            .disabled(record.phase == .preparing)
            if record.canSave {
                Button("skills.mcp.creation.add_connection") { Task { await coordinator.saveSelected() } }
                    .accessibilityIdentifier("skills.mcp.creation.save")
            }
            if record.phase == .failed || record.phase == .interrupted {
                Button("skills.mcp.creation.resume") { coordinator.resumeSelected() }
            }
            if record.phase != .added && record.phase != .stopped {
                Button(LocalizedStringKey(record.phase == .stopping && !coordinator.isStopping
                    ? "skills.mcp.creation.retry_stop" : "skills.mcp.creation.cancel"), role: .destructive) {
                    Task { await coordinator.cancelSelected() }
                }
                .disabled(coordinator.isStopping)
            }
        }
        DisclosureGroup("skills.mcp.creation.details") {
            Text(record.request.details).textSelection(.enabled)
            if let error = record.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let binding = record.binding { Text(binding.projectRelativePath).font(.caption.monospaced()) }
            if let receipt = record.receipt { Text(receipt.endpoint.absoluteString).font(.caption).textSelection(.enabled) }
        }
    }
}
#endif

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeAgentRuntime

@MainActor
final class MemoryCenter: ObservableObject {
    @Published private(set) var entries: [MemoryEntry] = []
    @Published var errorMessage: String?
    unowned let environment: AppEnvironment

    init(environment: AppEnvironment) { self.environment = environment }

    func load() async {
        var result: [MemoryEntry] = []
        result += (try? await environment.intelligenceStore.memories(scope: .userProfile, status: nil)) ?? []
        result += (try? await environment.intelligenceStore.memories(scope: .agentGlobal, status: nil)) ?? []
        if let workspace = environment.workspaceCenter.currentWorkspace {
            result += (try? await environment.intelligenceStore.memories(scope: .workspace(workspace.id), status: nil)) ?? []
        }
        if let conversationID = environment.browserCenter.conversationID {
            result += (try? await environment.intelligenceStore.memories(
                scope: .task(conversationID), status: nil
            )) ?? []
        }
        entries = result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func remember(_ content: String, workspaceOnly: Bool, taskOnly: Bool = false) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let scope: MemoryScope
        if taskOnly, let conversationID = environment.browserCenter.conversationID {
            scope = .task(conversationID)
        } else if workspaceOnly, let workspace = environment.workspaceCenter.currentWorkspace {
            scope = .workspace(workspace.id)
        } else {
            scope = .userProfile
        }
        do {
            try await environment.intelligenceStore.saveMemory(MemoryEntry(
                scope: scope, status: .active, content: trimmed,
                confidence: 1, importance: 0.8, isPinned: true,
                sourceKind: .explicitUserRequest
            ), evidence: [])
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ entry: MemoryEntry) async {
        do { try await environment.intelligenceStore.deleteMemory(id: entry.id, syncRevision: 1); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct MemoryView: View {
    @ObservedObject var center: MemoryCenter
    @State private var showingAdd = false

    var body: some View {
        List {
            if center.entries.isEmpty {
                ContentUnavailableView("memory.empty", systemImage: "brain")
            } else {
                ForEach(center.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.content)
                        Text(scope(entry.scope)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("action.delete", role: .destructive) { Task { await center.delete(entry) } } }
                }
            }
            if let error = center.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("memory.title")
        .toolbar { Button("memory.add", systemImage: "plus") { showingAdd = true } }
        .task { await center.load() }
        .sheet(isPresented: $showingAdd) { AddMemorySheet(center: center) }
    }

    private func scope(_ scope: MemoryScope) -> LocalizedStringKey {
        switch scope {
        case .userProfile: "memory.scope.user"
        case .agentGlobal: "memory.scope.agent"
        case .workspace: "memory.scope.workspace"
        case .task: "任务记忆"
        }
    }
}

private struct AddMemorySheet: View {
    @ObservedObject var center: MemoryCenter
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var workspaceOnly = false
    @State private var taskOnly = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("memory.content", text: $content, axis: .vertical).lineLimit(4...10)
                Toggle("memory.workspace_only", isOn: $workspaceOnly)
                    .disabled(taskOnly)
                Toggle("仅当前任务", isOn: $taskOnly)
                    .disabled(center.environment.browserCenter.conversationID == nil)
            }
            .navigationTitle("memory.add")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("memory.save") {
                        Task {
                            await center.remember(
                                content,
                                workspaceOnly: workspaceOnly,
                                taskOnly: taskOnly
                            )
                            dismiss()
                        }
                    }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif

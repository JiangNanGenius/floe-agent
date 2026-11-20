// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// The ordinary chat can address a Space original after its owner selects it.
/// No model-supplied ID can invoke this picker or enumerate the library.
@MainActor struct OrdinaryWorkPicker: View {
    let taskID: UUID
    let isDraft: Bool
    let environment: AppEnvironment
    let selected: (PersonalContentRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [PersonalContentRecord] = []
    @State private var grants: Set<UUID> = []
    @State private var editable = true
    @State private var busy = true
    @State private var failure: String?
    @State private var query = ""
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            List {
                Toggle(IDELanguageRunText.t("允许此任务编辑原件", "Allow this task to edit the original"), isOn: $editable)
                ForEach(records.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { record in
                    Button { choose(record) } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(record.title)
                                    Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: record.kind.systemImage) }
                            Spacer()
                            if grants.contains(record.id) { Image(systemName: "checkmark") }
                        }
                    }
                    .swipeActions {
                        if grants.contains(record.id) {
                            Button(role: .destructive) {
                                update {
                                    try await environment.studioCoordinator.access.get().revokeAccess(conversationID: taskID, projectID: record.id)
                                    grants.remove(record.id)
                                }
                            } label: { Label(IDELanguageRunText.t("移除访问", "Remove access"), systemImage: "minus.circle") }
                        }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .overlay { if busy { ProgressView() } }
            .disabled(busy)
            .searchable(text: $query)
            .navigationTitle(IDELanguageRunText.t("空间作品", "Space works"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("关闭", "Close")) { dismiss() }
                }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .task {
                defer { busy = false }
                do {
                    // Game source uses the task's bound workspace. Biology uses
                    // its own project assistant and native execution authority.
                    records = try await PersonalContentService.shared.library().records().filter {
                        !$0.needsRecovery && $0.kind != .game && $0.kind != .biology
                    }
                    grants = Set(try await environment.studioCoordinator.access.get().projectIDs(conversationID: taskID))
                } catch { failure = error.localizedDescription }
            }
        }
    }

    private func choose(_ record: PersonalContentRecord) {
        update {
            if let task = try await environment.conversationStore.conversation(id: taskID) {
                guard task.isVisibleInOrdinaryList else { throw PersonalContentError.changedDocument }
            } else if !isDraft {
                throw PersonalContentError.changedDocument
            }
            let current = try await PersonalContentService.shared.library().resolve(record.id).record
            guard current.kind == record.kind, !current.needsRecovery else { throw PersonalContentError.changedDocument }
            guard isVisible else { return }
            try PersonalLibraryFileActions.requireAvailable(current.id)
            try await environment.studioCoordinator.access.get().setUserSelectedWork(current.id, conversationID: taskID, editable: editable)
            guard isVisible else { return }
            selected(current)
            dismiss()
        }
    }

    private func update(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { failure = error.localizedDescription }
        }
    }
}
#endif

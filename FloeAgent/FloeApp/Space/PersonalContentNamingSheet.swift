// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// One naming presentation freezes its target and destination. It is a UI
/// request, not a new document identity or storage/permission authority.
struct PersonalContentCreationRequest: Identifiable {
    enum Target {
        case work(PersonalContentKind)
        case document(PersonalOfficeFormat)
    }
    let id = UUID()
    let target: Target
    let folders: [String]
    var suggestedTitle: String {
        switch target {
        case .work(let kind): kind.title
        case .document(let format): format.title
        }
    }
    var heading: String {
        switch target {
        case .work: IDELanguageRunText.t("新建作品", "New work")
        case .document: IDELanguageRunText.t("新建文档", "New document")
        }
    }
}

/// Save while this sheet is mounted. The parent opens the saved record only
/// from sheet.onDismiss, after the naming and keyboard presentation has ended.
struct PersonalContentNamingSheet: View {
    let request: PersonalContentCreationRequest
    let onCreated: (PersonalContentRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var creating = false
    @State private var diagnostic: String?

    init(request: PersonalContentCreationRequest, onCreated: @escaping (PersonalContentRecord) -> Void) {
        self.request = request; self.onCreated = onCreated
        _title = State(initialValue: request.suggestedTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(IDELanguageRunText.t("名称", "Name"), text: $title)
                        .disabled(creating)
                        .accessibilityIdentifier("space.creation.title")
                    LabeledContent(IDELanguageRunText.t("位置", "Location"),
                        value: ([IDELanguageRunText.t("我的文件", "My files")] + request.folders).joined(separator: " / "))
                        .foregroundStyle(.secondary)
                }
                if creating {
                    ProgressView(IDELanguageRunText.t("正在创建…", "Creating…"))
                        .accessibilityIdentifier("space.creation.progress")
                }
                if let diagnostic {
                    Section {
                        Label(IDELanguageRunText.t("未能创建，请重试", "Unable to create. Try again"), systemImage: "exclamationmark.triangle")
                        Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.accessibilityIdentifier("space.creation.error")
                }
            }
            .navigationTitle(request.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {
                        guard !creating else { return }
                        dismiss()
                    }
                        .disabled(creating)
                        .accessibilityIdentifier("space.creation.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("创建", "Create")) { create() }
                        .disabled(creating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("space.creation.create")
                }
            }
        }
        .interactiveDismissDisabled(creating)
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !creating, !name.isEmpty else { return }
        creating = true; diagnostic = nil
        // An explicit owner task is retained through the save; transient
        // SwiftUI body reconstruction must not cancel the native factory.
        Task { @MainActor in
            do {
                let record: PersonalContentRecord
                switch request.target {
                case .work(let kind):
                    record = try await PersonalContentService.shared.create(kind: kind, title: name, folders: request.folders)
                case .document(let format):
                    record = try await PersonalContentService.shared.createDocument(format: format, title: name, folders: request.folders)
                }
                // Keep busy until dismissal to block a second Create. Failure
                // keeps this input and destination mounted for an explicit retry.
                onCreated(record)
                dismiss()
            } catch {
                diagnostic = error.localizedDescription
                creating = false
            }
        }
    }
}
#endif

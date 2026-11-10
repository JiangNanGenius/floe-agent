// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeLaTeXCore

/// One naming presentation freezes its target and initial destination. It is a UI
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
    @EnvironmentObject private var environment: AppEnvironment
    @State private var title: String
    @State private var destinationFolders: [String]
    @State private var choosingLocation = false
    @State private var creating = false
    @FocusState private var titleFocused: Bool
    @State private var diagnostic: String?
    @State private var latexTemplate=IDELanguageRunText.isChinese ? "chinese":"article"

    init(request: PersonalContentCreationRequest, onCreated: @escaping (PersonalContentRecord) -> Void) {
        self.request = request; self.onCreated = onCreated
        _title = State(initialValue: request.suggestedTitle)
        _destinationFolders = State(initialValue: request.folders)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(IDELanguageRunText.t("名称", "Name"), text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { create() }
                        .disabled(creating)
                        .accessibilityIdentifier("space.creation.title")
                    Button { choosingLocation = true } label: {
                        LabeledContent(IDELanguageRunText.t("位置", "Location")) {
                            HStack {
                                Text(([IDELanguageRunText.t("我的文件", "My files")] + destinationFolders).joined(separator: " / "))
                                    .foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.trailing)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .disabled(creating)
                    .accessibilityIdentifier("space.creation.location")
                }
                if creating {
                    ProgressView(IDELanguageRunText.t("正在创建…", "Creating…"))
                        .accessibilityIdentifier("space.creation.progress")
                }
                if case .work(.latex)=request.target {
                    Section(IDELanguageRunText.t("模板","Template")) {
                        Picker(IDELanguageRunText.t("文档类型","Document type"),selection:$latexTemplate) {
                            ForEach(LaTeXTemplates.all) {value in Text(IDELanguageRunText.isChinese ? value.chineseTitle:value.englishTitle).tag(value.id)}
                        }.disabled(creating).accessibilityIdentifier("latex.creation.template")
                    }
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
                        titleFocused = false
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
        .sheet(isPresented: $choosingLocation) {
            PersonalLibraryFolderPicker(initialFolders: destinationFolders) { destinationFolders = $0 }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !creating, !name.isEmpty else { return }
        titleFocused = false
        creating = true; diagnostic = nil
        let destination = destinationFolders
        // An explicit owner task is retained through the save; transient
        // SwiftUI body reconstruction must not cancel the native factory.
        Task { @MainActor in
            do {
                let record: PersonalContentRecord
                switch request.target {
                case .work(let kind):
                    if kind == .biology { _ = try await environment.biologyComposition.host() }
                    if kind == .latex {
                        _ = try await environment.latexComposition.host()
                        record=try await PersonalContentService.shared.createLaTeX(title:name,templateID:latexTemplate,folders:destination)
                    } else {record = try await PersonalContentService.shared.create(kind: kind, title: name, folders:destination)}
                case .document(let format):
                    record = try await PersonalContentService.shared.createDocument(format: format, title: name, folders: destination)
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

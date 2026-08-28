// FloeApp — basic native Office editor for bounded OOXML text and cells.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeDocuments
import FloeCore

struct OfficeDocumentEditorView: View {
    let relativePath: String
    @ObservedObject var center: WorkspaceCenter
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: OfficeDocumentSnapshot?
    @State private var original: [String: String] = [:]
    @State private var values: [String: String] = [:]
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var saveNotice: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("office.editor.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else if let snapshot {
                List {
                    summary(snapshot)
                    ForEach(grouped(snapshot), id: \.section) { group in
                        Section(group.section) {
                            ForEach(group.fields) { field in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(field.label)
                                        .font(FloeTheme.Typography.metadata)
                                        .foregroundStyle(.secondary)
                                    TextField(
                                        field.label,
                                        text: binding(for: field.id),
                                        axis: .vertical
                                    )
                                    .lineLimit(1...10)
                                    .textInputAutocapitalization(.sentences)
                                    .autocorrectionDisabled(snapshot.kind == .workbook)
                                    .font(snapshot.kind == .workbook
                                        ? FloeTheme.Typography.evidence
                                        : FloeTheme.Typography.body)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let saveNotice {
                        Label(saveNotice, systemImage: "checkmark.circle.fill")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.success)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
            } else {
                ProgressView("office.editor.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle((relativePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("office.editor.close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text("office.editor.save") }
                }
                .disabled(isSaving || changedValues.isEmpty || snapshot == nil)
            }
        }
        .interactiveDismissDisabled(isSaving || !changedValues.isEmpty)
        .task(id: relativePath) { await load() }
    }

    @ViewBuilder
    private func summary(_ snapshot: OfficeDocumentSnapshot) -> some View {
        Section {
            LabeledContent("office.editor.format", value: snapshot.kind.rawValue.uppercased())
            LabeledContent("office.editor.fields", value: String(snapshot.fields.count))
        } footer: {
            Text("office.editor.scope_hint")
        }
    }

    private func grouped(_ snapshot: OfficeDocumentSnapshot) -> [(section: String, fields: [OfficeEditableField])] {
        var order: [String] = []
        var groups: [String: [OfficeEditableField]] = [:]
        for field in snapshot.fields {
            if groups[field.section] == nil { order.append(field.section) }
            groups[field.section, default: []].append(field)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { values[id] = $0; saveNotice = nil }
        )
    }

    private var changedValues: [String: String] {
        values.reduce(into: [:]) { result, item in
            if original[item.key] != item.value { result[item.key] = item.value }
        }
    }

    private func localURL() throws -> URL {
        guard !center.isCloudWorkspacePath(relativePath) else {
            throw OfficeDocumentError.unsupportedFormat
        }
        guard let service = center.fileService else {
            throw FloeError.validationFailed("No workspace is open")
        }
        return try service.guardResolver.resolve(relativePath)
    }

    @MainActor
    private func load() async {
        loadError = nil
        do {
            let url = try localURL()
            let loaded = try await Task.detached {
                try OfficeDocumentService.inspect(url: url)
            }.value
            snapshot = loaded
            original = Dictionary(uniqueKeysWithValues: loaded.fields.map { ($0.id, $0.text) })
            values = original
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        let updates = changedValues
        guard !updates.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let url = try localURL()
            let updated = try await Task.detached {
                try OfficeDocumentService.update(sourceURL: url, updates: updates)
            }.value
            snapshot = updated
            original = Dictionary(uniqueKeysWithValues: updated.fields.map { ($0.id, $0.text) })
            values = original
            saveNotice = String(localized: "office.editor.saved")
            onSaved?()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
#endif

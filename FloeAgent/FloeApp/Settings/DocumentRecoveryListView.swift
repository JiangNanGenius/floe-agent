#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeDocuments

struct DocumentRecoveryListView: View {
    @State private var records: [DocumentRecoveryRecord] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
            }
            if loading { ProgressView() }
            ForEach(records) { record in
                NavigationLink {
                    RecoveredOfficePreview(record: record)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayName)
                            Text(record.updatedAt, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "doc.badge.clock") }
                }
            }
            if !loading, error == nil, records.isEmpty {
                ContentUnavailableView("没有保留的文档", systemImage: "doc.badge.clock")
            }
        }
        .navigationTitle("保留的文档")
        .task { await load() }
        .refreshable { await load() }
    }
    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let workspace = try SecurityScopedDocumentWorkspace()
            records = try await workspace.recoveryRecords()
        } catch { self.error = error.localizedDescription }
    }
}

private struct RecoveredOfficePreview: View {
    let record: DocumentRecoveryRecord
    @StateObject private var session = OfficeFileSession()
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    private var usesOfficeHost: Bool {
        OfficeFileSession.available &&
            ["docx", "xlsx", "pptx"].contains(record.workingURL.pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if !usesOfficeHost {
                QuickLookView(url: record.workingURL)
            } else if editing {
                ContentUnavailableView("正在全屏编辑", systemImage: "doc.richtext")
            } else {
                OfficeDocumentSurface(session: session)
            }
        }
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { Task { await session.release(); dismiss() } }
            }
            ToolbarItem(placement: .primaryAction) {
                if usesOfficeHost {
                    Button("全屏编辑", systemImage: "square.and.pencil") { editing = true }
                        .disabled(!session.canAct)
                }
            }
        }
        .task(id: record.id) {
            if usesOfficeHost { await session.resumeRecovery(id: record.id) }
        }
        .fullScreenCover(isPresented: $editing, onDismiss: {
            Task { await session.previewCurrent() }
        }) {
            NavigationStack {
                OfficeDocumentEditorView(relativePath: record.displayName, session: session)
            }
        }
        .onDisappear {
            if !editing { Task { await session.release() } }
        }
    }
}
#endif

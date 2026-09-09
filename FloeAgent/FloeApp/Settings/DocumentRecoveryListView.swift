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
    @State private var choosingVersion = false
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
                    HStack {
                        Button("查看保留版本", systemImage: "clock.arrow.circlepath") { choosingVersion = true }
                        Button("全屏编辑", systemImage: "square.and.pencil") { editing = true }
                    }.disabled(!session.canAct)
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
        .sheet(isPresented: $choosingVersion) {
            NavigationStack { DocumentRecoveryVersionsView(session: session) }
        }
        .onDisappear {
            if !editing && !choosingVersion { Task { await session.release() } }
        }
    }
}

private struct DocumentRecoveryVersionsView: View {
    @ObservedObject var session: OfficeFileSession
    @State private var versions: [DocumentRecoveryVersion] = []
    @State private var loading = true
    @State private var choosing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("选择要恢复的内容。当前副本会保留为另一个版本，原文件不会改变。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(versions) { version in
                Button {
                    choosing = true
                    Task {
                        if await session.useRecoveryVersion(version) { dismiss() }
                        else { error = session.error }
                        choosing = false
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(version.kind)).foregroundStyle(.primary)
                            Text(version.updatedAt, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(version.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if version.kind == .current { Image(systemName: "checkmark") }
                    }
                }.disabled(choosing || !session.canAct || version.kind == .current)
            }
        }
        .navigationTitle("保留的版本")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(choosing) }
        }
        .interactiveDismissDisabled(choosing)
        .task {
            defer { loading = false }
            do { versions = try await session.recoveryVersions() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func title(_ kind: DocumentRecoveryVersion.Kind) -> String {
        switch kind {
        case .current: "当前副本"
        case .lastSave: "上次保存尝试"
        case .editor: "编辑器保留的副本"
        case .previousEdit: "之前的编辑"
        case .export: "已准备的导出副本"
        }
    }
}
#endif

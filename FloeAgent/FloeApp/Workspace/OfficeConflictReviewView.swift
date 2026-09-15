// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeDocuments

struct OfficeConflictCopies: Sendable {
    let mine: DocumentExportSnapshot
    let current: DocumentExportSnapshot
    let owner: SecurityScopedDocumentWorkspace
    func release() async {
        await owner.finishExport(mine)
        await owner.finishExport(current)
    }
}

/// Office packages are compared as immutable document versions, never merged
/// by concatenating XML/ZIP bytes or by guessing that text covers formatting.
struct OfficeConflictReviewView: View {
    @ObservedObject var session: OfficeFileSession
    @Environment(\.dismiss) private var dismiss
    @State private var copies: OfficeConflictCopies?
    @State private var failure: String?
    @State private var preview: DocumentExportSnapshot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("edit.conflict.officeExplanation").foregroundStyle(.secondary)
                    if let copies {
                        version("edit.conflict.mine", snapshot: copies.mine)
                        version("edit.conflict.current", snapshot: copies.current)
                        Label("edit.conflict.officeRetained", systemImage: "checkmark.shield")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        ProgressView("edit.conflict.loadingVersions")
                    }
                }.padding(24)
            }
            .navigationTitle("edit.conflict.compareVersions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } } }
            .sheet(item: $preview) { snapshot in
                NavigationStack {
                    QuickLookView(url: snapshot.fileURL)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { preview = nil } } }
                }
            }
        }
        .task {
            do {
                let result = try await session.conflictCopies()
                if Task.isCancelled { await result.release() } else { copies = result }
            } catch { failure = error.localizedDescription }
        }
        .onDisappear {
            if let copies { Task { await copies.release() }; self.copies = nil }
        }
    }

    private func version(_ title: LocalizedStringKey, snapshot: DocumentExportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "doc.richtext").font(.headline)
            HStack(spacing: 20) {
                Button("edit.conflict.openVersion") { preview = snapshot }
                    .buttonStyle(.bordered)
                ShareLink(item: snapshot.fileURL) {
                    Label("edit.conflict.exportVersion", systemImage: "square.and.arrow.up")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif

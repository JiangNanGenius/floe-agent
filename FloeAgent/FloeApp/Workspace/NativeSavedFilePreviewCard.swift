// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeModels

/// Shows an actual committed-file preview when an earlier revision is not
/// comparable. This is never rendered as an all-added diff or given totals.
struct NativeSavedFilePreviewCard: View {
    let document: WorkspaceFileChangePreview
    let disposition: NativeFileDiffDisposition
    @State private var showingPreview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(document.path, systemImage: "doc.text")
                .font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Button(NativeFileDiffCopy.t("预览文件", "Preview file"), systemImage: "doc.text.magnifyingglass") {
                showingPreview = true
            }
            .font(.caption).frame(minHeight: 44)
            .accessibilityIdentifier("fileDiff.previewSavedFile")
        }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 0) {
                    if document.truncated {
                        Text(NativeFileDiffCopy.t("这里只显示部分内容，保存的文件保持完整。", "This is a partial preview. The saved file is complete."))
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                    if document.text.isEmpty {
                        ContentUnavailableView(NativeFileDiffCopy.t("空文件", "Empty file"), systemImage: "doc")
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(verbatim: document.text)
                                .font(FloeTheme.Typography.evidence)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle((document.path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(NativeFileDiffCopy.t("完成", "Done")) { showingPreview = false }
                } }
            }
            .presentationDetents([.large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fileDiff.comparisonUnavailable")
    }
    private var message: String {
        guard disposition == .applied else {
            return NativeFileDiffCopy.t("这份预览没有可比较的旧内容。", "Earlier contents are unavailable for this preview.")
        }
        switch document.comparison {
        case .unchanged: return NativeFileDiffCopy.t("文件已保存，内容没有变化。", "File saved with no content changes.")
        case .baselineUnavailable: return NativeFileDiffCopy.t("文件已保存，无法与原内容比较。", "File saved. Earlier contents could not be compared.")
        case .comparisonTooLarge: return NativeFileDiffCopy.t("文件已保存，可预览当前内容。", "File saved. Preview the current contents.")
        }
    }
}
#endif

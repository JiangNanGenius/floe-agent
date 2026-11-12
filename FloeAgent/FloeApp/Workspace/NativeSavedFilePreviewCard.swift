// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeModels

/// Shows an actual committed-file preview when an earlier revision is not
/// comparable. This is never rendered as an all-added diff or given totals.
struct NativeSavedFilePreviewCard: View {
    let document: WorkspaceFileChangePreview
    let artifact: ToolArtifactReference
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.chatInlineContentScope) private var scope
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
            TextReaderView(source: SavedFileTextPreviewPolicy.source(document: document, artifact: artifact,
                scope: scope, environment: environment))
                .id("\(artifact.id)#\(document.sha256)")
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

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeCore

enum NativeFileDiffCopy {
    static func t(_ zh: String, _ en: String) -> String { FloeL10n.bilingual(chinese: zh, english: en) }
}

/// Visible result content, deliberately outside the tool's technical-detail
/// disclosure. Five means additions + removals, not number of hunks/rows.
struct NativeFileChangeCard: View {
    let diffText: String
    let disposition: NativeFileDiffDisposition
    var fileURL: URL? = nil
    private let expandedByParent: Bool
    private let document: NativeFileDiff?
    @State private var expanded = false
    @State private var fullDiff = false
    @State private var viewportHeight: Double?
    @State private var measuredRows: (text: String, height: Double)?

    init(diffText: String, disposition: NativeFileDiffDisposition = .reference, fileURL: URL? = nil,
         expandedByParent: Bool = false) {
        self.diffText = diffText; self.disposition = disposition; self.fileURL = fileURL
        self.expandedByParent = expandedByParent
        document = try? NativeFileDiff(unifiedDiff: diffText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(compact: false).fixedSize(horizontal: true, vertical: false)
                header(compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            if let document {
                if document.showsChangesByDefault || expandedByParent || expanded {
                    Divider()
                    DiffView(document: document, changesOnly: document.showsChangesByDefault, omitsSingleFileHeader: true,
                        onContentHeightChange: { height in
                            let rounded = height.rounded(.up)
                            if measuredRows?.text != diffText || measuredRows?.height != rounded {
                                measuredRows = (diffText, rounded)
                            }
                        })
                        // New immutable evidence must get a fresh measurement,
                        // including when its intrinsic height equals the old one.
                        .id(diffText)
                        .frame(height: rowsHeight(document))
                }
            } else {
                Text(FloeL10n.l("app.native_file_change_card.line_counts_are_unavailable_open"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FloeTheme.readingSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(FloeTheme.separator.opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: Double?.self) { geometry in
            // Read the nearest enclosing conversation/inspector viewport,
            // before our internal scroll area. Never choose a UIWindow.
            geometry.bounds(of: .scrollView(axis: .vertical)).map { Double($0.height) }
        } action: { viewportHeight = $0 }
        .sheet(isPresented: $fullDiff) {
            NavigationStack {
                DiffView(diffText: diffText)
                    .navigationTitle(FloeL10n.l("app.native_file_change_card.file_diff"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(FloeL10n.l("help.done")) { fullDiff = false }
                        }
                        if let fileURL {
                            ToolbarItem(placement: .secondaryAction) {
                                ShareLink(item: fileURL) { Label(FloeL10n.l("app.native_file_change_card.share_diff"), systemImage: "square.and.arrow.up") }
                            }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fileDiff.result")
    }
    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Label(title, systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                .accessibilityValue(dispositionText)
            if let document {
                HStack(spacing: 6) {
                    Text("+\(document.added)").foregroundStyle(FloeTheme.success)
                        .accessibilityLabel(FloeL10n.l("app.native_file_change_card.added_lines", document.added))
                    Text("−\(document.removed)").foregroundStyle(FloeTheme.destructive)
                        .accessibilityLabel(FloeL10n.l("app.native_file_change_card.removed_lines", document.removed))
                }.font(.caption.monospacedDigit()).fixedSize()
                if !document.showsChangesByDefault && !expandedByParent {
                    Button { expanded.toggle() } label: {
                        if compact {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .frame(minWidth: 44, minHeight: 44)
                        } else {
                            Label(expanded ? FloeL10n.l("app.native_file_change_card.collapse_diff") : FloeL10n.l("app.native_file_change_card.expand_diff"), systemImage: expanded ? "chevron.up" : "chevron.down")
                                .frame(minHeight: 44)
                        }
                    }.font(.caption).buttonStyle(.borderless)
                        .accessibilityLabel(expanded ? FloeL10n.l("app.native_file_change_card.collapse_diff") : FloeL10n.l("app.native_file_change_card.expand_diff"))
                        .accessibilityIdentifier("fileDiff.expand")
                }
            }
            if disposition == .proposal {
                Text(FloeL10n.l("app.native_file_change_card.not_saved"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Button { fullDiff = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
            }.buttonStyle(.borderless)
                .accessibilityLabel(FloeL10n.l("app.native_file_change_card.open_full_diff"))
                .accessibilityIdentifier("fileDiff.openFull")
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("fileDiff.header")
    }
    private var title: String {
        guard let document else { return FloeL10n.l("app.native_file_change_card.file_changes") }
        if document.paths.count == 1 { return document.paths[0] }
        if document.paths.count > 1 { return FloeL10n.l("app.native_file_change_card.files", document.paths.count) }
        return FloeL10n.l("app.native_file_change_card.file_changes")
    }
    private var dispositionText: String {
        switch disposition {
        case .applied: FloeL10n.l("app.native_file_change_card.saved")
        case .proposal: FloeL10n.l("app.native_file_change_card.preview_not_saved")
        case .reference: FloeL10n.l("app.native_file_change_card.diff_record")
        }
    }
    private func rowsHeight(_ document: NativeFileDiff) -> Double {
        let cap = NativeFileDiffLayout.maximumHeight(isPad: UIDevice.current.userInterfaceIdiom == .pad, viewportHeight: viewportHeight)
        // The actual enclosing viewport supplies the initial measurement
        // budget. Large diffs keep this bounded, internally scrollable area.
        guard document.showsChangesByDefault, let measuredRows, measuredRows.text == diffText else { return cap }
        return min(cap, measuredRows.height)
    }
}
#endif

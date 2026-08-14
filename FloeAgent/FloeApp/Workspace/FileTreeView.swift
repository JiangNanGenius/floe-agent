// FloeApp — Lazy directory tree with search.
//
// SPDX-License-Identifier: MPL-2.0
//
// OutlineGroup-based tree over FileTreeViewModel. Typing in the search
// field switches to a flat hit list (path + line number + context).
// Selecting a file opens the preview through FileInspectorView.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeWorkspace

/// The workspace directory tree (lazy) with an inline search field.
struct FileTreeView: View {
    @ObservedObject var viewModel: FileTreeViewModel
    /// Called when the user taps a file (tree mode) or a hit (search mode).
    let onSelectFile: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(text: $viewModel.query) {
                Text("inspector.search.placeholder")
            }
            .textFieldStyle(.plain)
            .accessibilityLabel("inspector.search.placeholder")
            if viewModel.isSearching {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.search.clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            searchResults
        } else if viewModel.rootNodes.isEmpty {
            emptyState
        } else {
            treeList
        }
    }

    private var treeList: some View {
        List {
            OutlineGroup(viewModel.rootNodes, children: \.children) { node in
                FileTreeRow(node: node) {
                    if !node.isDirectory {
                        onSelectFile(node.relativePath)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var searchResults: some View {
        Group {
            if viewModel.searchHits.isEmpty {
                ContentUnavailableView {
                    Label("inspector.search.empty", systemImage: "magnifyingglass")
                } description: {
                    Text(viewModel.query)
                }
            } else {
                List(viewModel.searchHits, id: \.self) { hit in
                    Button {
                        onSelectFile(hit.relativePath)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(hit.relativePath):\(hit.lineNumber)")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(hit.context)
                                .font(FloeTheme.Typography.evidence)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("inspector.tree.empty", systemImage: "folder")
        } description: {
            if let message = viewModel.errorMessage {
                Text(message)
            } else {
                Text("inspector.tree.empty.hint")
            }
        }
    }
}

/// One tree row. Directories disclose via OutlineGroup; tapping a file
/// selects it.
private struct FileTreeRow: View {
    let node: FileTreeNode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label {
                Text(node.name)
                    .font(FloeTheme.Typography.body)
                    .lineLimit(1)
            } icon: {
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .foregroundStyle(node.isDirectory ? FloeTheme.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Directories keep their disclosure hit area; the button still
        // satisfies the 44pt minimum target on compact layouts.
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(node.name)
        .accessibilityAddTraits(node.isDirectory ? [] : .isButton)
    }
}
#endif

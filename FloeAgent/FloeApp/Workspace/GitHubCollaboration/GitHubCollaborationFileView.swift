// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGit

struct GitHubCollaborationFileView: View {
    @Bindable var center: GitHubCollaborationCenter
    let file: GitHubCollaborationFile
    @State private var viewedHeadSHA: String?
    @State private var viewedSelection: GitHubCollaborationSelection?
    private let document: NativeFileDiff?
    init(center: GitHubCollaborationCenter, file: GitHubCollaborationFile) {
        self.center = center; self.file = file
        _viewedHeadSHA = State(initialValue: center.pull?.head.sha)
        _viewedSelection = State(initialValue: center.selection)
        let old = (file.previousFilename ?? file.filename).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let new = file.filename.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        document = file.patch.flatMap { try? NativeFileDiff(unifiedDiff: "--- a/" + old + "\n+++ b/" + new + "\n" + $0 + "\n") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(file.filename).font(.headline.monospaced()).textSelection(.enabled)
                if let old = file.previousFilename { Text(old + " → " + file.filename).font(.caption).foregroundStyle(.secondary) }
                HStack { Text("+\(file.additions)").foregroundStyle(.green); Text("−\(file.deletions)").foregroundStyle(.red) }.font(.caption.monospacedDigit())
                if let error = center.operationError { GitHubCollaborationNotice(message: error) }
                if viewedHeadSHA != center.pull?.head.sha || viewedSelection != center.selection {
                    GitHubCollaborationNotice(message: ghCollabText("此文件已有更新。请返回文件列表刷新后再评论。", "This file changed. Return to the file list and refresh before commenting."))
                }
            }.padding(12)
            Divider()
            if let document {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(line.oldNumber.map(String.init) ?? "").foregroundStyle(.secondary).frame(minWidth: 48, alignment: .trailing)
                                Text(line.newNumber.map(String.init) ?? "").foregroundStyle(.secondary).frame(minWidth: 48, alignment: .trailing).padding(.trailing, 8)
                                Text(prefix(line) + line.content).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(line.kind == .removal ? Color.red : line.kind == .addition ? Color.green : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let anchor = anchor(line) {
                                    Button {
                                        Task { await center.beginDraft(.lineComment, line: anchor, viewedHeadSHA: viewedHeadSHA, viewedFile: file, viewedSelection: viewedSelection) }
                                    } label: { Image(systemName: "plus.bubble").frame(width: 44, height: 44) }
                                    .disabled(!center.canWrite || viewedHeadSHA != center.pull?.head.sha || viewedSelection != center.selection)
                                    .accessibilityLabel(ghCollabText("评论第 \(anchor.line) 行", "Comment on line \(anchor.line)"))
                                    .accessibilityIdentifier("github.collaboration.line.\(anchor.side.rawValue).\(anchor.line)")
                                }
                            }
                            .font(.system(.footnote, design: .monospaced))
                            .padding(.vertical, 2).padding(.trailing, 8)
                            .background(line.kind == .addition ? Color.green.opacity(0.08) : line.kind == .removal ? Color.red.opacity(0.08) : Color.clear)
                        }
                    }
                }
            } else {
                ContentUnavailableView(ghCollabText("此文件未提供完整行内差异", "A complete inline diff is unavailable"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(ghCollabText("二进制或较大的更改可在 GitHub 查看。", "View binary or larger changes on GitHub.")))
            }
        }
        .navigationTitle(ghCollabText("文件更改", "File changes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) {
            if let number = viewedSelection?.number,
               let url = ghCollabWebURL(center.scope.repository, ["pull", String(number), "files"]) {
                Link(ghCollabText("在 GitHub 打开", "Open on GitHub"), destination: url)
            }
        } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.file.diff")
    }
    private func prefix(_ line: NativeFileDiff.Line) -> String {
        line.kind == .addition ? "+ " : line.kind == .removal ? "− " : "  "
    }
    private func anchor(_ line: NativeFileDiff.Line) -> GitHubReviewLine? {
        let value: GitHubReviewLine?
        switch line.kind {
        case .addition, .context: value = line.newNumber.map { .init(path: file.filename, side: .right, line: $0) }
        case .removal: value = line.oldNumber.map { .init(path: file.filename, side: .left, line: $0) }
        default: value = nil
        }
        guard let value, (try? value.validate(in: [file])) != nil else { return nil }
        return value
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGit

/// A saved native snapshot, not an implicit refresh or web-title substitute.
struct GitHubSourceDetails: View {
    let snapshot: GitHubLinkSnapshot
    var isBusy = false
    let openCollaboration: (() -> Void)?
    let workInNewTask: (() -> Void)?
    private func text(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
    private var title: String {
        snapshot.pullRequest?.title ?? snapshot.issue?.title ?? snapshot.file?.path
            ?? snapshot.commit?.message.components(separatedBy: .newlines).first ?? snapshot.repository.identity.fullName
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(snapshot.repository.identity.fullName, systemImage: "shippingbox").font(.subheadline).foregroundStyle(.secondary)
                    Text(title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let number = snapshot.link.number {
                        Label("#\(number) · " + (snapshot.pullRequest?.state ?? snapshot.issue?.state ?? ""),
                            systemImage: snapshot.pullRequest == nil ? "exclamationmark.circle" : "arrow.triangle.pull")
                    }
                    if let description = snapshot.repository.description, snapshot.link.kind == .repository {
                        Text(description).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let openCollaboration {
                        Button(action: openCollaboration) {
                            Label(text("打开问题与拉取请求", "Open issues and pull requests"), systemImage: "bubble.left.and.bubble.right")
                        }.buttonStyle(.borderedProminent).disabled(isBusy).accessibilityIdentifier("github.source.collaborate")
                    }
                    if let workInNewTask {
                        Button(action: workInNewTask) {
                            Label(text("在新任务中处理", "Work in a new task"), systemImage: "square.and.pencil")
                        }.buttonStyle(.bordered).disabled(isBusy).accessibilityIdentifier("github.source.newTask")
                    }
                }
                if let location = snapshot.location {
                    VStack(alignment: .leading, spacing: 8) {
                        if let selected = location.selectedComment {
                            Label(text("链接中的讨论", "Linked discussion"), systemImage: "text.bubble").font(.headline)
                            comment(selected)
                        }
                        if let selected = location.selectedText {
                            Label(location.path ?? text("链接中的内容", "Linked content"), systemImage: "text.alignleft").font(.headline)
                            if let start = location.startLine { Text(start == location.endLine ? "L\(start)" : "L\(start)–L\(location.endLine ?? start)").font(.caption).foregroundStyle(.secondary) }
                            GitHubSourceText(text: selected, code: true)
                        }
                        if location.state != .resolved {
                            Text(text("此处保留这次读取的定位结果；尚未读取的讨论或历史行不会自动补齐。", "This is the saved location. Discussions or historical lines outside the read are not automatically fetched."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
                if let sha = snapshot.link.pullRequestCommit {
                    Label(text("此链接引用历史提交；协作页显示当前拉取请求。", "This link references a historical commit; collaboration opens the current pull request."), systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(String(sha.prefix(12))).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let issue = snapshot.issue { GitHubSourceText(text: issue.body, code: false); comments(issue.comments) }
                if let pull = snapshot.pullRequest {
                    GitHubSourceText(text: pull.body, code: false)
                    Label(pull.head.ref + " → " + pull.base.ref, systemImage: "arrow.triangle.branch").font(.callout)
                    changes(pull.files); comments(pull.comments)
                }
                if let commit = snapshot.commit {
                    GitHubSourceText(text: commit.message, code: false)
                    changes(commit.files)
                }
                if let file = snapshot.file {
                    if let contents = file.text { GitHubSourceText(text: contents, code: true) }
                    else { Label(text("本次读取未包含可显示的文件正文", "No displayable file content was included in this read"), systemImage: "doc") }
                }
                if let directory = snapshot.directory {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("目录", "Directory")).font(.headline)
                        ForEach(Array(directory.items.enumerated()), id: \.offset) { _, entry in
                            Label(entry.path, systemImage: entry.type == "tree" ? "folder" : "doc").font(.body.monospaced()).textSelection(.enabled)
                        }
                        continuation(directory.nextPage)
                    }
                }
                if let readme = snapshot.readme?.text {
                    VStack(alignment: .leading, spacing: 8) { Text("README").font(.headline); GitHubSourceText(text: readme, code: false) }
                }
                DisclosureGroup(text("来源详情", "Source details")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Link(text("打开原链接", "Open original link"), destination: snapshot.source.originalURL)
                        Text(snapshot.source.resolvedURL.absoluteString).font(.caption).textSelection(.enabled)
                        if let revision = snapshot.source.revision {
                            Text(revision.name).font(.caption)
                            Text(revision.commitSHA).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text(snapshot.source.readAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }.frame(maxWidth: 960, alignment: .leading).padding(20).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("github.source.details")
    }
    @ViewBuilder private func continuation(_ next: Int?) -> some View {
        if next != nil { Text(text("还有未读取的内容，可让助手继续读取。", "More content remains. Ask the assistant to continue reading.")).font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func comments(_ page: GitHubLinkPage<GitHubLinkComment>?) -> some View {
        if let page {
            VStack(alignment: .leading, spacing: 14) {
                Text(text("讨论", "Discussion")).font(.headline)
                ForEach(Array(page.items.enumerated()), id: \.offset) { _, value in comment(value) }
                continuation(page.nextPage)
            }
        }
    }
    private func comment(_ value: GitHubLinkComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.author ?? "GitHub").font(.subheadline.weight(.semibold))
            if let path = value.path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary) }
            GitHubSourceText(text: value.body, code: false)
            if let hunk = value.diffHunk { GitHubSourceText(text: hunk, code: true) }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private func changes(_ page: GitHubLinkPage<GitHubLinkChangedFile>?) -> some View {
        if let page {
            VStack(alignment: .leading, spacing: 12) {
                Text(text("文件变更", "File changes")).font(.headline)
                ForEach(Array(page.items.enumerated()), id: \.offset) { _, file in
                    DisclosureGroup {
                        if let patch = file.patch { GitHubSourceText(text: patch, code: true) }
                        else { Text(text("本次读取没有包含此文件的差异正文。", "This read did not include the file's patch.")) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.filename).font(.callout.monospaced()).textSelection(.enabled)
                            Text("+\(file.additions) −\(file.deletions)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                continuation(page.nextPage)
            }
        }
    }
}
private struct GitHubSourceText: View {
    let text: String
    let code: Bool
    @State private var limit = 32_768
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(text.prefix(limit))).font(code ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if text.count > limit {
                Button(FloeL10n.isChinese ? "显示更多内容" : "Show more") { limit += 32_768 }
            }
        }
    }
}
#endif

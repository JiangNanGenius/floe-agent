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
                            Label(FloeL10n.l("app.git_hub_source_details.open_issues_and_pull_requests"), systemImage: "bubble.left.and.bubble.right")
                        }.buttonStyle(.borderedProminent).disabled(isBusy).accessibilityIdentifier("github.source.collaborate")
                    }
                    if let workInNewTask {
                        Button(action: workInNewTask) {
                            Label(FloeL10n.l("app.git_hub_source_details.work_in_a_new_task"), systemImage: "square.and.pencil")
                        }.buttonStyle(.bordered).disabled(isBusy).accessibilityIdentifier("github.source.newTask")
                    }
                }
                if let location = snapshot.location {
                    VStack(alignment: .leading, spacing: 8) {
                        if let selected = location.selectedComment {
                            Label(FloeL10n.l("app.git_hub_source_details.linked_discussion"), systemImage: "text.bubble").font(.headline)
                            comment(selected)
                        }
                        if let selected = location.selectedText {
                            Label(location.path ?? FloeL10n.l("app.git_hub_source_details.linked_content"), systemImage: "text.alignleft").font(.headline)
                            if let start = location.startLine { Text(start == location.endLine ? "L\(start)" : "L\(start)–L\(location.endLine ?? start)").font(.caption).foregroundStyle(.secondary) }
                            GitHubSourceText(text: selected, code: true)
                        }
                        if location.state != .resolved {
                            Text(FloeL10n.l("app.git_hub_source_details.this_is_the_saved_location"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
                if let sha = snapshot.link.pullRequestCommit {
                    Label(FloeL10n.l("app.git_hub_source_details.this_link_references_a_historical"), systemImage: "clock.arrow.circlepath")
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
                    else { Label(FloeL10n.l("app.git_hub_source_details.no_displayable_file_content_was"), systemImage: "doc") }
                }
                if let directory = snapshot.directory {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(FloeL10n.l("app.git_hub_source_details.directory")).font(.headline)
                        ForEach(Array(directory.items.enumerated()), id: \.offset) { _, entry in
                            Label(entry.path, systemImage: entry.type == "tree" ? "folder" : "doc").font(.body.monospaced()).textSelection(.enabled)
                        }
                        continuation(directory.nextPage)
                    }
                }
                if let readme = snapshot.readme?.text {
                    VStack(alignment: .leading, spacing: 8) { Text("README").font(.headline); GitHubSourceText(text: readme, code: false) }
                }
                DisclosureGroup(FloeL10n.l("app.git_hub_source_details.source_details")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Link(FloeL10n.l("app.git_hub_source_details.open_original_link"), destination: snapshot.source.originalURL)
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
        if next != nil { Text(FloeL10n.l("app.git_hub_source_details.more_content_remains_ask_the")).font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func comments(_ page: GitHubLinkPage<GitHubLinkComment>?) -> some View {
        if let page {
            VStack(alignment: .leading, spacing: 14) {
                Text(FloeL10n.l("app.git_hub_source_details.discussion")).font(.headline)
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
                Text(FloeL10n.l("app.git_hub_source_details.file_changes")).font(.headline)
                ForEach(Array(page.items.enumerated()), id: \.offset) { _, file in
                    DisclosureGroup {
                        if let patch = file.patch { GitHubSourceText(text: patch, code: true) }
                        else { Text(FloeL10n.l("app.git_hub_source_details.this_read_did_not_include")) }
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
                Button(FloeL10n.l("app.git_hub_source_details.show_more")) { limit += 32_768 }
            }
        }
    }
}
#endif

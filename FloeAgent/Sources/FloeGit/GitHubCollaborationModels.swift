// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

private func gitHubCollaborationText(_ english: String, _ chinese: String) -> String { FloeL10n.isChinese ? chinese : english }

public enum GitHubCollaborationError: Error, Sendable, Equatable, LocalizedError {
    case invalidInput(String), authenticationRequired, changedHead(expected: String, actual: String)
    case unavailableDiff, invalidLine, incompletePage, outcomeUnknown(UUID), rejected(Int), operationMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidInput: gitHubCollaborationText("Check the required fields and try again.", "请检查必填内容后重试。")
        case .authenticationRequired: gitHubCollaborationText("Connect GitHub to send this change.", "连接 GitHub 后可发送此更改。")
        case .changedHead: gitHubCollaborationText("This pull request changed. Refresh it before continuing.", "此拉取请求已有更新，请刷新后继续。")
        case .unavailableDiff, .invalidLine: gitHubCollaborationText("Refresh the changed file and select a line in its current diff.", "请刷新更改的文件，并在当前差异中选择行。")
        case .incompletePage: gitHubCollaborationText("More results are available. Load the next page to continue.", "还有更多结果，请加载下一页。")
        case .outcomeUnknown: gitHubCollaborationText("The response was interrupted. Check the result before sending again.", "响应中断，请先核对结果，再决定是否重新发送。")
        case .rejected: gitHubCollaborationText("GitHub did not accept this change. Check the details and try again.", "GitHub 未接受此更改，请查看详情后重试。")
        case .operationMismatch: gitHubCollaborationText("This action belongs to a different task or request.", "此操作属于另一个任务或请求。")
        }
    }
}

public struct GitHubCollaborationThread: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let number: Int
    public let title: String
    public let body: String?
    public let state: String
    public let htmlURL: URL
    public let updatedAt: String
    public let user: Author?
    public let pullRequest: PullReference?
    public struct Author: Codable, Sendable, Hashable { public let login: String }
    public struct PullReference: Codable, Sendable, Hashable { public let url: URL }
    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, user
        case htmlURL = "html_url", updatedAt = "updated_at", pullRequest = "pull_request"
    }
}
public struct GitHubCollaborationPull: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let number: Int
    public let title: String
    public let body: String?
    public let state: String
    public let draft: Bool
    public let user: GitHubCollaborationThread.Author?
    public let merged: Bool?
    public let htmlURL: URL
    public let head: Side
    public let base: Side
    public let changedFiles: Int?
    public let mergeable: Bool?
    public let mergeableState: String?
    public struct Side: Codable, Sendable, Hashable {
        public let ref: String
        public let sha: String
        public let label: String
        public let repo: Repository?
    }
    public struct Repository: Codable, Sendable, Hashable {
        public let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, draft, merged, head, base, mergeable, user
        case htmlURL = "html_url", changedFiles = "changed_files", mergeableState = "mergeable_state"
    }
}
public struct GitHubCollaborationComment: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let body: String
    public let htmlURL: URL
    public let user: GitHubCollaborationThread.Author?
    public let commitID: String?
    public let state: String?
    public let path: String?
    public let line: Int?
    public let side: String?
    public let startLine: Int?
    enum CodingKeys: String, CodingKey {
        case id, body, user, state, path, line, side
        case htmlURL = "html_url", commitID = "commit_id", startLine = "start_line"
    }
}
public struct GitHubCollaborationFile: Codable, Sendable, Identifiable, Hashable {
    public var id: String { filename }
    public let sha: String
    public let filename: String
    public let previousFilename: String?
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let patch: String?
    enum CodingKeys: String, CodingKey {
        case sha, filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }
}
public struct GitHubCollaborationCheck: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let status: String
    public let conclusion: String?
    public let headSHA: String
    public let htmlURL: URL?
    enum CodingKeys: String, CodingKey { case id, name, status, conclusion; case headSHA = "head_sha", htmlURL = "html_url" }
}
public struct GitHubCollaborationCommitStatus: Codable, Sendable, Hashable {
    public let state: String
    public let sha: String
    public let statuses: [Status]
    public struct Status: Codable, Sendable, Identifiable, Hashable {
        public let id: Int64
        public let context: String
        public let state: String
        public let description: String?
        public let targetURL: URL?
        enum CodingKeys: String, CodingKey { case id, context, state, description; case targetURL = "target_url" }
    }
}
public struct GitHubCollaborationPage<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let page: Int
    /// A full page is conservatively treated as having a successor. Never
    /// represent a size-capped list as a complete repository snapshot.
    public let nextPage: Int?
}
public struct GitHubReviewLine: Codable, Sendable, Hashable {
    public enum Side: String, Codable, Sendable { case left = "LEFT", right = "RIGHT" }
    public let path: String
    public let side: Side
    public let line: Int
    public let startLine: Int?
    public init(path: String, side: Side, line: Int, startLine: Int? = nil) {
        self.path = path; self.side = side; self.line = line; self.startLine = startLine
    }
    /// Resolve against actual current patch hunks. An omitted/binary/truncated
    /// patch is not a license to submit an invented line anchor.
    public func validate(in files: [GitHubCollaborationFile]) throws {
        guard line > 0, startLine == nil || (startLine! > 0 && startLine! <= line),
              let file = files.first(where: { $0.filename == path }), let patch = file.patch,
              patch.utf8.count <= 1_048_576 else { throw GitHubCollaborationError.unavailableDiff }
        var old = 0, new = 0, hunk = 0
        var positions = [Int: Int]()
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        for part in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(part), range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
               let o = Int(text[a]), let n = Int(text[b]) { old = o; new = n; hunk += 1; continue }
            guard hunk > 0, let prefix = text.first else { continue }
            if prefix == "-" { if side == .left { positions[old] = hunk }; old += 1 }
            else if prefix == "+" { if side == .right { positions[new] = hunk }; new += 1 }
            else if prefix == " " { if side == .right { positions[new] = hunk }; old += 1; new += 1 }
        }
        guard let containing = positions[line] else { throw GitHubCollaborationError.invalidLine }
        if let startLine {
            guard line - startLine <= 10_000,
                  (startLine...line).allSatisfy({ positions[$0] == containing }) else { throw GitHubCollaborationError.invalidLine }
        }
    }
}

public enum GitHubReviewEvent: String, Codable, Sendable { case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES" }
public enum GitHubMergeMethod: String, Codable, Sendable { case merge, squash, rebase }

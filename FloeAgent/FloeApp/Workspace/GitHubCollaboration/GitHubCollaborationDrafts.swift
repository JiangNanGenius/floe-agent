// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeGit

func ghCollabText(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }

func ghCollabWebURL(_ repository: GitHubLinkRepositoryID, _ path: [String]) -> URL? {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#\\"))
    let segments = [repository.owner, repository.name] + path
    let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
    guard encoded.count == segments.count,
          let link = try? GitHubLinkParser.parse("https://github.com/" + encoded.joined(separator: "/")),
          link.repository == repository else { return nil }
    return link.url
}

struct GitHubCollaborationScope: Codable, Sendable, Hashable {
    let repository: GitHubLinkRepositoryID
    let workspaceID: UUID?
    let sourceTaskID: UUID?
    var ownerID: UUID? { sourceTaskID ?? workspaceID }
    var storageKey: String {
        FloeDigest.sha256Hex(Data((repository.fullName + ":" +
            (workspaceID?.uuidString ?? "") + ":" + (sourceTaskID?.uuidString ?? "")).utf8))
    }
}

enum GitHubCollaborationSelection: Hashable, Identifiable {
    case issue(Int), pull(Int)
    var number: Int { switch self { case .issue(let n), .pull(let n): n } }
    var id: String { switch self { case .issue(let n): "issue-\(n)"; case .pull(let n): "pull-\(n)" } }
}

struct GitHubCollaborationDraft: Codable, Sendable, Equatable, Identifiable {
    private(set) var id: UUID
    let scope: GitHubCollaborationScope
    let kind: GitHubPreparedMutation.Kind
    var title = ""
    var body = ""
    var number: Int?
    var headSHA: String?
    var head = ""
    var base = ""
    var headRepository: GitHubLinkRepositoryID?
    var draftPull = false
    var reviewEvent: GitHubReviewEvent = .comment
    var reviewLine: GitHubReviewLine?
    var mergeMethod: GitHubMergeMethod = .squash
    var closeIssue = false
    var actionRun: GitHubActionAttempt?
    var prepared = false
    var updatedAt = Date()

    init(scope: GitHubCollaborationScope, kind: GitHubPreparedMutation.Kind, number: Int? = nil) {
        id = UUID(); self.scope = scope; self.kind = kind; self.number = number
    }
    var caption: String {
        switch kind {
        case .createIssue: ghCollabText("新建问题", "New issue")
        case .updateIssue: closeIssue ? ghCollabText("关闭问题", "Close issue") : ghCollabText("重新打开问题", "Reopen issue")
        case .reply: ghCollabText("回复", "Reply")
        case .createPull: ghCollabText("新建拉取请求", "New pull request")
        case .review: ghCollabText("评审拉取请求", "Review pull request")
        case .lineComment: ghCollabText("评论代码行", "Comment on a line")
        case .mergePull: ghCollabText("合并拉取请求", "Merge pull request")
        case .rerunActions: ghCollabText("重新运行", "Re-run jobs")
        case .rerunFailedActions: ghCollabText("重跑失败作业", "Re-run failed jobs")
        case .cancelActions: ghCollabText("取消运行", "Cancel run")
        }
    }
    func validate() throws {
        guard scope.ownerID != nil, title.count <= 256, body.utf8.count <= 65_000,
              head.utf8.count <= 1024, base.utf8.count <= 1024 else {
            throw GitHubCollaborationError.invalidInput("draft")
        }
        _ = try GitHubLinkParser.parse("https://github.com/" + scope.repository.fullName)
    }
    func editableCopy() -> Self {
        var copy = self; copy.id = UUID(); copy.prepared = false; copy.updatedAt = Date()
        return copy
    }
}

/// UI drafts are separate from the injected, immutable mutation journal.
/// One file per frozen owner/project/repository; no credential is a field.
actor GitHubCollaborationDraftStore {
    private struct Envelope: Codable {
        var version = 1
        let scope: GitHubCollaborationScope
        var drafts: [GitHubCollaborationDraft]
    }
    private let scope: GitHubCollaborationScope
    private let directory: URL
    private var location: URL { directory.appendingPathComponent(scope.storageKey + ".json") }
    init(scope: GitHubCollaborationScope, directory: URL? = nil) throws {
        self.scope = scope
        let support = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/GitHubCollaborationDrafts", isDirectory: true)
        self.directory = support.standardizedFileURL.resolvingSymlinksInPath()
    }
    func load() throws -> [GitHubCollaborationDraft] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let facts = try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true, (facts.fileSize ?? .max) <= 2_097_152 else {
            throw GitHubCollaborationError.invalidInput("draft storage")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: location))
        guard envelope.version == 1, envelope.scope == scope, envelope.drafts.count <= 24,
              Set(envelope.drafts.map(\.id)).count == envelope.drafts.count else { throw GitHubCollaborationError.operationMismatch }
        try envelope.drafts.forEach { draft in
            guard draft.scope == scope else { throw GitHubCollaborationError.operationMismatch }
            try draft.validate()
        }
        return envelope.drafts.sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ draft: GitHubCollaborationDraft) throws {
        try Task.checkCancellation()
        guard draft.scope == scope else { throw GitHubCollaborationError.operationMismatch }
        try draft.validate()
        var values = try load()
        if let prior = values.first(where: { $0.id == draft.id }) {
            // Fenced late autosaves cannot unlock a prepared request or
            // replace a newer UI snapshot after a sheet has closed.
            if prior.prepared && !draft.prepared || prior.updatedAt > draft.updatedAt { return }
            var identity = draft; identity.updatedAt = prior.updatedAt
            if prior.prepared && prior != identity { throw GitHubCollaborationError.operationMismatch }
        }
        values.removeAll { $0.id == draft.id }
        guard values.count < 24 else { throw GitHubCollaborationError.invalidInput("too many drafts") }
        values.append(draft); try write(values)
    }
    func remove(_ id: UUID) throws {
        var values = try load(); values.removeAll { $0.id == id }; try write(values)
    }
    private func write(_ drafts: [GitHubCollaborationDraft]) throws {
        let data = try JSONEncoder().encode(Envelope(scope: scope, drafts: drafts))
        guard data.count <= 2_097_152 else { throw GitHubCollaborationError.invalidInput("draft storage full") }
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw GitHubCollaborationError.operationMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: location.path) {
            let facts = try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard facts.isRegularFile == true, facts.isSymbolicLink != true else { throw GitHubCollaborationError.operationMismatch }
        }
        try data.write(to: location, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

/// App windows that refer to the same frozen scope share one draft writer.
/// This is not the remote mutation journal and never contains credentials.
@MainActor enum GitHubCollaborationDraftStores {
    private static var stores: [GitHubCollaborationScope: GitHubCollaborationDraftStore] = [:]
    static func store(for scope: GitHubCollaborationScope) throws -> GitHubCollaborationDraftStore {
        if let value = stores[scope] { return value }
        let value = try GitHubCollaborationDraftStore(scope: scope)
        stores[scope] = value
        return value
    }
}
#endif

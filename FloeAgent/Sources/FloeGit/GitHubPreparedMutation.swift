// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

public struct GitHubPreparedMutation: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case createIssue, updateIssue, reply, createPull, review, lineComment, mergePull, rerunActions, rerunFailedActions, cancelActions }
    public let id: UUID
    public let ownerTaskID: UUID
    public let repository: GitHubLinkRepositoryID
    public let kind: Kind
    public let number: Int?
    public let expectedHeadSHA: String?
    public let reviewLine: GitHubReviewLine?
    public let runID: Int64?
    public let runAttempt: Int?
    let endpoint: [String]
    let method: String
    let payload: Data
    public let targetURL: URL
    public var marker: String { "<!-- floe-operation:" + id.uuidString.lowercased() + " -->" }
    public var requestSHA256: String {
        var identity: [String] = [id.uuidString, ownerTaskID.uuidString, kind.rawValue, repository.owner, repository.name]
        identity.append(contentsOf: [method, endpoint.joined(separator: "/"), number.map { String($0) } ?? "", expectedHeadSHA ?? ""])
        identity.append(contentsOf: [reviewLine?.path ?? "", reviewLine?.side.rawValue ?? "", reviewLine.map { String($0.line) } ?? ""])
        let start = reviewLine.flatMap { $0.startLine }.map { String($0) } ?? ""
        identity.append(contentsOf: [start, runID.map { String($0) } ?? "", runAttempt.map { String($0) } ?? "", targetURL.absoluteString])
        var bytes = (try? JSONSerialization.data(withJSONObject: identity)) ?? Data()
        bytes.append(payload); return FloeDigest.sha256Hex(bytes)
    }
    func validateContract() throws {
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        guard let object, payload.count <= 131_072, method == (kind == .mergePull ? "PUT" : kind == .updateIssue ? "PATCH" : "POST") else { throw GitHubCollaborationError.operationMismatch }
        let numberString = number.map(String.init) ?? ""
        let expected: [String]; let keys: Set<String>
        switch kind {
        case .createIssue: expected = ["issues"]; keys = ["title", "body"]
        case .updateIssue: expected = ["issues", numberString]; keys = ["state"]
        case .reply: expected = ["issues", numberString, "comments"]; keys = ["body"]
        case .createPull: expected = ["pulls"]; keys = object.keys.contains("head_repo") ? ["title", "body", "head", "head_repo", "base", "draft"] : ["title", "body", "head", "base", "draft"]
        case .review: expected = ["pulls", numberString, "reviews"]; keys = ["commit_id", "event", "body"]
        case .lineComment:
            expected = ["pulls", numberString, "comments"]
            keys = reviewLine?.startLine == nil ? ["commit_id", "path", "line", "side", "body"] : ["commit_id", "path", "line", "side", "start_line", "start_side", "body"]
        case .mergePull: expected = ["pulls", numberString, "merge"]; keys = ["sha", "merge_method"]
        case .rerunActions, .rerunFailedActions, .cancelActions:
            expected = ["actions", "runs", runID.map(String.init) ?? "", kind == .cancelActions ? "cancel" : kind == .rerunFailedActions ? "rerun-failed-jobs" : "rerun"]
            keys = []
        }
        guard endpoint == expected, Set(object.keys) == keys else { throw GitHubCollaborationError.operationMismatch }
        let hasNumber = [.updateIssue, .reply, .review, .lineComment, .mergePull].contains(kind)
        let isActions = [.rerunActions, .rerunFailedActions, .cancelActions].contains(kind)
        guard hasNumber == (number != nil), !hasNumber || number! > 0,
              isActions == (runID != nil && runAttempt != nil), !isActions || (runID! > 0 && runAttempt! > 0),
              (kind == .lineComment) == (reviewLine != nil) else { throw GitHubCollaborationError.operationMismatch }
        if let sha = expectedHeadSHA {
            guard [40, 64].contains(sha.utf8.count), sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GitHubCollaborationError.operationMismatch }
        }
        if keys.contains("body") { guard let body = object["body"] as? String, body.hasSuffix(marker), body.utf8.count <= 65_100 else { throw GitHubCollaborationError.operationMismatch } }
        if keys.contains("title") { guard let value = object["title"] as? String, !value.isEmpty, value.count <= 256 else { throw GitHubCollaborationError.operationMismatch } }
        if kind == .createPull {
            guard expectedHeadSHA != nil, let head = object["head"] as? String, let base = object["base"] as? String,
                  !head.isEmpty, !base.isEmpty else { throw GitHubCollaborationError.operationMismatch }
            if object.keys.contains("head_repo") {
                guard let name = object["head_repo"] as? String else { throw GitHubCollaborationError.operationMismatch }
                try Self.validateHeadRepository(name, head: head, target: repository)
            }
        }
        if kind == .review || kind == .lineComment { guard expectedHeadSHA != nil, object["commit_id"] as? String == expectedHeadSHA else { throw GitHubCollaborationError.operationMismatch } }
        if kind == .review { guard let event = object["event"] as? String, GitHubReviewEvent(rawValue: event) != nil else { throw GitHubCollaborationError.operationMismatch } }
        if let line = reviewLine {
            guard line.line > 0, line.startLine == nil || (line.startLine! > 0 && line.startLine! <= line.line),
                  object["path"] as? String == line.path, object["line"] as? Int == line.line,
                  object["side"] as? String == line.side.rawValue,
                  object["start_line"] as? Int == line.startLine,
                  line.startLine == nil || object["start_side"] as? String == line.side.rawValue else { throw GitHubCollaborationError.operationMismatch }
        }
        if kind == .mergePull { guard expectedHeadSHA != nil, object["sha"] as? String == expectedHeadSHA, let method = object["merge_method"] as? String, GitHubMergeMethod(rawValue: method) != nil else { throw GitHubCollaborationError.operationMismatch } }
        if isActions { guard expectedHeadSHA != nil else { throw GitHubCollaborationError.operationMismatch } }
        let link = try GitHubLinkParser.parse("https://github.com/" + repository.fullName)
        let expectedURL = try GitHubLinkParser.webURL([repository.owner, repository.name] + (runID.map { ["actions", "runs", String($0)] } ?? number.map { [kind == .reply || kind == .updateIssue ? "issues" : "pull", String($0)] } ?? []))
        guard link.repository == repository, targetURL == expectedURL else { throw GitHubCollaborationError.operationMismatch }
        if kind == .updateIssue { guard let state = object["state"] as? String, ["open", "closed"].contains(state) else { throw GitHubCollaborationError.operationMismatch } }
    }
    private init(id: UUID, ownerTaskID: UUID, repository: GitHubLinkRepositoryID, kind: Kind,
                 number: Int? = nil, headSHA: String? = nil, reviewLine: GitHubReviewLine? = nil,
                 runID: Int64? = nil, runAttempt: Int? = nil, endpoint: [String], method: String = "POST", object: [String: Any]) throws {
        let link = try GitHubLinkParser.parse("https://github.com/" + repository.fullName)
        guard link.kind == .repository, link.repository == repository,
              number == nil || number! > 0, runID == nil || runID! > 0,
              runAttempt == nil || runAttempt! > 0 else { throw GitHubCollaborationError.invalidInput("target") }
        if let sha = headSHA {
            guard [40, 64].contains(sha.utf8.count), sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GitHubCollaborationError.invalidInput("head") }
        }
        self.id = id; self.ownerTaskID = ownerTaskID; self.repository = repository; self.kind = kind
        self.number = number; expectedHeadSHA = headSHA; self.reviewLine = reviewLine; self.runID = runID; self.runAttempt = runAttempt
        self.endpoint = endpoint; self.method = method
        payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard payload.count <= 131_072 else { throw GitHubCollaborationError.invalidInput("body") }
        targetURL = try GitHubLinkParser.webURL([repository.owner, repository.name] + (runID.map { ["actions", "runs", String($0)] } ?? number.map { [kind == .reply || kind == .updateIssue ? "issues" : "pull", String($0)] } ?? []))
    }
    private static func body(_ text: String, id: UUID, allowEmpty: Bool = false) throws -> String {
        guard allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65_000, !text.contains("\0") else { throw GitHubCollaborationError.invalidInput("body") }
        return text + "\n\n<!-- floe-operation:" + id.uuidString.lowercased() + " -->"
    }
    private static func title(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 256, result.rangeOfCharacter(from: .controlCharacters) == nil else { throw GitHubCollaborationError.invalidInput("title") }; return result
    }
    public static func issue(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, title: String, body: String) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .createIssue, endpoint: ["issues"], object: ["title": Self.title(title), "body": Self.body(body, id: id, allowEmpty: true)])
    }
    public static func issueState(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, number: Int, closed: Bool) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .updateIssue, number: number, endpoint: ["issues", String(number)], method: "PATCH", object: ["state": closed ? "closed" : "open"])
    }
    public static func reply(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, number: Int, body: String) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .reply, number: number, endpoint: ["issues", String(number), "comments"], object: ["body": Self.body(body, id: id)])
    }
    public static func pull(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, title: String, body: String, head: String, base: String, headSHA: String, draft: Bool = false, headRepository: String? = nil) throws -> Self {
        for value in [head, base] { guard !value.isEmpty, value.utf8.count <= 1024, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw GitHubCollaborationError.invalidInput("branch") } }
        var object: [String: Any] = ["title": try Self.title(title), "body": try Self.body(body, id: id, allowEmpty: true), "head": head, "base": base, "draft": draft]
        if let headRepository { try validateHeadRepository(headRepository, head: head, target: repository); object["head_repo"] = headRepository }
        return try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .createPull, headSHA: headSHA, endpoint: ["pulls"], object: object)
    }
    private static func validateHeadRepository(_ name: String, head: String, target: GitHubLinkRepositoryID) throws {
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].contains(":"), !name.isEmpty else { throw GitHubCollaborationError.invalidInput("head repository") }
        let id = GitHubLinkRepositoryID(owner: parts[0], name: name)
        let link = try GitHubLinkParser.parse("https://github.com/" + id.fullName)
        guard link.kind == .repository, link.repository == id else { throw GitHubCollaborationError.invalidInput("head repository") }
    }
    public static func review(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, number: Int, headSHA: String, event: GitHubReviewEvent, body: String) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .review, number: number, headSHA: headSHA, endpoint: ["pulls", String(number), "reviews"], object: ["commit_id": headSHA, "event": event.rawValue, "body": Self.body(body, id: id, allowEmpty: event == .approve)])
    }
    public static func lineComment(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, number: Int, headSHA: String, line: GitHubReviewLine, body: String) throws -> Self {
        guard !line.path.isEmpty, !line.path.hasPrefix("/"), !line.path.split(separator: "/").contains(".."), !line.path.contains("\0") else { throw GitHubCollaborationError.invalidInput("path") }
        var object: [String: Any] = ["commit_id": headSHA, "path": line.path, "line": line.line, "side": line.side.rawValue, "body": try Self.body(body, id: id)]
        if let start = line.startLine { object["start_line"] = start; object["start_side"] = line.side.rawValue }
        return try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .lineComment, number: number, headSHA: headSHA, reviewLine: line, endpoint: ["pulls", String(number), "comments"], object: object)
    }
    public static func merge(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, number: Int, headSHA: String, method: GitHubMergeMethod) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .mergePull, number: number, headSHA: headSHA, endpoint: ["pulls", String(number), "merge"], method: "PUT", object: ["sha": headSHA, "merge_method": method.rawValue])
    }
    public static func rerun(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, runID: Int64, attempt: Int, headSHA: String, failedOnly: Bool) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: failedOnly ? .rerunFailedActions : .rerunActions, headSHA: headSHA, runID: runID, runAttempt: attempt, endpoint: ["actions", "runs", String(runID), failedOnly ? "rerun-failed-jobs" : "rerun"], object: [:])
    }
    public static func cancelRun(id: UUID = UUID(), ownerTaskID: UUID, repository: GitHubLinkRepositoryID, runID: Int64, attempt: Int, headSHA: String) throws -> Self {
        try .init(id: id, ownerTaskID: ownerTaskID, repository: repository, kind: .cancelActions, headSHA: headSHA, runID: runID, runAttempt: attempt, endpoint: ["actions", "runs", String(runID), "cancel"], object: [:])
    }
}

public struct GitHubMutationResult: Codable, Sendable, Equatable {
    public enum Confirmation: String, Codable, Sendable { case acknowledged, observed }
    public let remoteID: Int64?
    public let url: URL
    public let commitSHA: String?
    public var confirmation: Confirmation = .acknowledged
}

public struct GitHubActionAttempt: Codable, Sendable, Equatable {
    public let id: Int64
    public let runAttempt: Int
    public let headSHA: String
    public let status: String
    public let conclusion: String?
    enum CodingKeys: String, CodingKey { case id, status, conclusion; case runAttempt = "run_attempt", headSHA = "head_sha" }
}

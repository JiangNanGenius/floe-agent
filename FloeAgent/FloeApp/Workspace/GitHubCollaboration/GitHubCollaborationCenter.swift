// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeGit

enum GitHubCollaborationSection: String, CaseIterable, Identifiable {
    case issues, pulls
    var id: String { rawValue }
    var title: String { self == .issues ? ghCollabText("问题", "Issues") : ghCollabText("拉取请求", "Pull requests") }
}
enum GitHubCollaborationCollection: String { case comments, reviews, lineComments, files, checks }
struct GitHubCollaborationDraftRoute: Identifiable { let id: UUID }

/// Frozen feature-local owner. It receives the app's ONE journal service;
/// changing the global selected workspace/task cannot retarget this instance.
@MainActor @Observable final class GitHubCollaborationCenter {
    let scope: GitHubCollaborationScope
    let initialLink: GitHubLink?
    var section: GitHubCollaborationSection = .issues
    var stateFilter = "open"
    var search = ""
    var selection: GitHubCollaborationSelection?
    var issues: [GitHubCollaborationThread] = []
    var pulls: [GitHubCollaborationPull] = []
    var listNextPage: Int?
    var listLoading = false
    var listError: String?
    var detailLoading = false
    var detailError: String?
    var issue: GitHubCollaborationThread?
    var pull: GitHubCollaborationPull?
    var comments: [GitHubCollaborationComment] = []
    var reviews: [GitHubCollaborationComment] = []
    var lineComments: [GitHubCollaborationComment] = []
    var files: [GitHubCollaborationFile] = []
    var checks: [GitHubCollaborationCheck] = []
    var commitStatus: GitHubCollaborationCommitStatus?
    var detailNextPages: [GitHubCollaborationCollection: Int] = [:]
    var collectionsLoading = Set<GitHubCollaborationCollection>()
    var collectionErrors: [GitHubCollaborationCollection: String] = [:]
    var statusError: String?
    var actionRun: GitHubActionAttempt?
    var drafts: [GitHubCollaborationDraft] = []
    var records: [GitHubMutationRecord] = []
    var draftRoute: GitHubCollaborationDraftRoute?
    var storageError: String?
    var operationError: String?
    var activeOperationID: UUID?
    var reconcilingID: UUID?
    var needsSignIn = false
    var headBranches: [GitHubCollaborationBranch] = []
    var baseBranches: [GitHubCollaborationBranch] = []
    var headNextPage: Int?
    var baseNextPage: Int?
    var branchesLoading = false

    @ObservationIgnored let client: GitHubCollaborationClient
    @ObservationIgnored let service: GitHubCollaborationService
    @ObservationIgnored let tokenProvider: @Sendable () throws -> String
    @ObservationIgnored let authorize: @Sendable () throws -> Void
    @ObservationIgnored var draftStore: GitHubCollaborationDraftStore?
    @ObservationIgnored var listGeneration = 0
    @ObservationIgnored var detailGeneration = 0
    @ObservationIgnored var branchGeneration = 0
    @ObservationIgnored var autosave: Task<Void, Never>?
    @ObservationIgnored var operationTask: Task<Void, Never>?

    init(repository: GitHubLinkRepositoryID, workspaceID: UUID?, sourceTaskID: UUID?,
         service: GitHubCollaborationService, client: GitHubCollaborationClient,
         tokenProvider: @escaping @Sendable () throws -> String, initialLink: GitHubLink? = nil,
         authorize: @escaping @Sendable () throws -> Void,
         draftStore: GitHubCollaborationDraftStore? = nil) {
        scope = .init(repository: repository, workspaceID: workspaceID, sourceTaskID: sourceTaskID)
        self.service = service; self.client = client; self.tokenProvider = tokenProvider; self.authorize = authorize
        self.initialLink = initialLink
        self.draftStore = draftStore
        if let link = initialLink, link.repository.fullName.caseInsensitiveCompare(repository.fullName) == .orderedSame,
           let number = link.number, number > 0 {
            if link.kind == .pullRequest { section = .pulls; selection = .pull(number) }
            else if link.kind == .issue { selection = .issue(number) }
        }
    }
    var canWrite: Bool {
        guard scope.ownerID != nil, storageError == nil else { return false }
        // The same native lease/context gates visible actions and execution.
        // A saved source can retain Return-to-task without acquiring writes.
        do { try authorize(); return true } catch { return false }
    }
    var selectedURL: URL? { issue?.htmlURL ?? pull?.htmlURL }

    func bootstrap() async {
        guard scope.ownerID != nil else { return }
        do {
            if draftStore == nil { draftStore = try GitHubCollaborationDraftStores.store(for: scope) }
            drafts = try await draftStore?.load() ?? []
            storageError = nil
            await refreshRecords()
            // A crash between prepare and a UI draft save still freezes the
            // same recorded payload. It must not become an editable resend.
            for index in drafts.indices where records.contains(where: { $0.id == drafts[index].id }) {
                drafts[index].prepared = true
            }
        } catch { storageError = ghCollabText("暂时无法读取草稿。请重试，原草稿仍保留。", "Drafts could not be opened. Retry; existing drafts are preserved.") }
    }
    func refreshRecords() async {
        guard let owner = scope.ownerID else { return }
        records = await service.recent(ownerTaskID: owner).filter { $0.request.repository == scope.repository }
    }
    func fenceReads() {
        listGeneration += 1; detailGeneration += 1; branchGeneration += 1
        listLoading = false; detailLoading = false; collectionsLoading = []; branchesLoading = false
    }
    func readToken() throws -> String {
        let token = try tokenProvider()
        if !token.isEmpty { needsSignIn = false }
        return token
    }
    func sendToken() throws -> String {
        let token = try readToken()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubCollaborationError.authenticationRequired }
        return token
    }
    func message(_ error: Error) -> String {
        if error is CancellationError { return ghCollabText("操作已取消。", "The action was cancelled.") }
        if let error = error as? GitHubCollaborationError {
            if error == .authenticationRequired { needsSignIn = true }
            return error.localizedDescription
        }
        if let error = error as? GitHubLinkError {
            switch error {
            case .authenticationRequired: needsSignIn = true; return ghCollabText("连接 GitHub 后重试。", "Connect GitHub and try again.")
            case .forbidden: return ghCollabText("当前账号无法访问此内容。请检查仓库权限。", "This account cannot access this content. Check repository access.")
            case .notFoundOrNotAccessible: return ghCollabText("找不到此内容，或当前账号无法访问。", "This content is missing or unavailable to this account.")
            case .rateLimited: return ghCollabText("GitHub 请求较多，请稍后刷新。", "GitHub is limiting requests. Refresh shortly.")
            case .sourceChanged: return ghCollabText("内容已有更新，请刷新后继续。", "The content changed. Refresh to continue.")
            default: break
            }
        }
        return ghCollabText("暂时无法完成，请重试或在 GitHub 查看。", "Unable to complete this action. Retry or view it on GitHub.")
    }
    func loadList(more: Bool = false) async {
        if more, listLoading { return }
        listGeneration += 1; let generation = listGeneration
        let tab = section, state = stateFilter, page = more ? listNextPage : 1
        guard let page else { return }
        listLoading = true; listError = nil
        defer { if generation == listGeneration { listLoading = false } }
        do {
            let token = try readToken()
            if tab == .issues {
                let result = try await client.issues(scope.repository, state: state, page: page, token: token)
                guard !Task.isCancelled, generation == listGeneration else { return }
                let actualIssues = result.items.filter { $0.pullRequest == nil }
                issues = more ? unique(issues + actualIssues) : actualIssues
                listNextPage = result.nextPage
            } else {
                let result = try await client.pulls(scope.repository, state: state, page: page, token: token)
                guard !Task.isCancelled, generation == listGeneration else { return }
                pulls = more ? unique(pulls + result.items) : result.items
                listNextPage = result.nextPage
            }
        } catch {
            guard !Task.isCancelled, generation == listGeneration else { return }
            listError = message(error)
        }
    }
    func loadDetail() async {
        detailGeneration += 1; let generation = detailGeneration
        guard let selected = selection else { return }
        detailLoading = true; detailError = nil; issue = nil; pull = nil
        comments = []; reviews = []; lineComments = []; files = []; checks = []; commitStatus = nil
        detailNextPages = [:]; actionRun = nil; collectionsLoading = []; collectionErrors = [:]; statusError = nil
        defer { if generation == detailGeneration { detailLoading = false } }
        do {
            let token = try readToken()
            switch selected {
            case .issue(let number):
                let item = try await client.issue(scope.repository, number: number, token: token)
                guard !Task.isCancelled, generation == detailGeneration, selection == selected else { return }
                issue = item
                await loadCollection(.comments, page: 1, append: false, generation: generation, selected: selected)
            case .pull(let number):
                let item = try await client.pull(scope.repository, number: number, token: token)
                guard !Task.isCancelled, generation == detailGeneration, selection == selected else { return }
                pull = item
                // Independent permissions or a failed checks endpoint cannot
                // make an otherwise readable conversation disappear.
                async let a: Void = loadCollection(.comments, page: 1, append: false, generation: generation, selected: selected)
                async let b: Void = loadCollection(.reviews, page: 1, append: false, generation: generation, selected: selected)
                async let c: Void = loadCollection(.lineComments, page: 1, append: false, generation: generation, selected: selected)
                async let d: Void = loadCollection(.files, page: 1, append: false, generation: generation, selected: selected)
                async let e: Void = loadCollection(.checks, page: 1, append: false, generation: generation, selected: selected)
                async let f: Void = loadStatus(generation: generation, selected: selected, head: item.head.sha)
                _ = await (a, b, c, d, e, f)
            }
        } catch {
            guard !Task.isCancelled, generation == detailGeneration else { return }
            detailError = message(error)
        }
    }
    func loadMore(_ collection: GitHubCollaborationCollection) async {
        guard let page = detailNextPages[collection], let selected = selection else { return }
        await loadCollection(collection, page: page, append: true, generation: detailGeneration, selected: selected)
    }
    func retryCollection(_ collection: GitHubCollaborationCollection) async {
        guard let selected = selection else { return }
        await loadCollection(collection, page: 1, append: false, generation: detailGeneration, selected: selected)
    }
    func loadCollection(_ collection: GitHubCollaborationCollection, page: Int, append: Bool,
                        generation: Int, selected: GitHubCollaborationSelection) async {
        guard generation == detailGeneration, selection == selected, !collectionsLoading.contains(collection) else { return }
        let head = pull?.head.sha
        collectionsLoading.insert(collection); collectionErrors[collection] = nil
        defer { if generation == detailGeneration { collectionsLoading.remove(collection) } }
        func current() -> Bool { generation == detailGeneration && selection == selected && !Task.isCancelled }
        do {
            let token = try readToken(), repo = scope.repository
            switch collection {
            case .comments:
                let result = try await client.comments(repo, number: selected.number, page: page, token: token)
                guard current() else { return }
                comments = append ? unique(comments + result.items) : result.items; detailNextPages[collection] = result.nextPage
            case .reviews, .lineComments:
                let result = try await (collection == .reviews
                    ? client.reviews(repo, number: selected.number, page: page, token: token)
                    : client.reviewComments(repo, number: selected.number, page: page, token: token))
                guard current() else { return }
                if collection == .reviews { reviews = append ? unique(reviews + result.items) : result.items }
                else { lineComments = append ? unique(lineComments + result.items) : result.items }
                detailNextPages[collection] = result.nextPage
            case .files:
                guard let head else { return }
                let result = try await client.files(repo, number: selected.number, page: page, token: token)
                _ = try await client.requireHead(repo, number: selected.number, expected: head, token: token)
                guard current() else { return }
                files = append ? unique(files + result.items) : result.items; detailNextPages[collection] = result.nextPage
            case .checks:
                guard let head else { return }
                let result = try await client.checks(repo, sha: head, page: page, token: token)
                guard current() else { return }
                checks = append ? unique(checks + result.items) : result.items; detailNextPages[collection] = result.nextPage
            }
        } catch { if current() { collectionErrors[collection] = message(error) } }
    }
    func loadStatus(generation: Int, selected: GitHubCollaborationSelection, head: String) async {
        do {
            let value = try await client.commitStatus(scope.repository, sha: head, token: readToken())
            guard generation == detailGeneration, selection == selected, !Task.isCancelled else { return }
            commitStatus = value; statusError = nil
        } catch {
            guard generation == detailGeneration, selection == selected, !Task.isCancelled else { return }
            statusError = message(error)
        }
    }
    func unique<Item: Identifiable>(_ values: [Item]) -> [Item] where Item.ID: Hashable {
        var seen = Set<Item.ID>(); return values.filter { seen.insert($0.id).inserted }
    }
}
#endif

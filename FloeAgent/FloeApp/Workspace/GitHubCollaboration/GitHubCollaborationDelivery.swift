// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGit

extension GitHubCollaborationCenter {
    func beginDraft(_ kind: GitHubPreparedMutation.Kind, line: GitHubReviewLine? = nil,
                    closeIssue: Bool = false, run: GitHubActionAttempt? = nil,
                    viewedHeadSHA: String? = nil, viewedFile: GitHubCollaborationFile? = nil,
                    viewedSelection: GitHubCollaborationSelection? = nil) async {
        guard canWrite, let draftStore else { return }
        do {
            if kind == .lineComment {
                guard selection == viewedSelection, let viewedHeadSHA, let viewedFile, pull?.head.sha == viewedHeadSHA,
                      files.first(where: { $0.filename == viewedFile.filename }) == viewedFile else { throw GitHubLinkError.sourceChanged }
            }
            var draft = GitHubCollaborationDraft(scope: scope, kind: kind, number: (kind == .createIssue || kind == .createPull) ? nil : selection?.number)
            draft.headSHA = pull?.head.sha; draft.reviewLine = line; draft.closeIssue = closeIssue; draft.actionRun = run
            if let line { try line.validate(in: files) }
            try await draftStore.save(draft)
            drafts = try await draftStore.load()
            draftRoute = .init(id: draft.id); operationError = nil
            if kind == .createPull { await loadBranches(for: draft.id) }
        } catch { operationError = message(error) }
    }
    func updateDraft(_ id: UUID, change: (inout GitHubCollaborationDraft) -> Void) {
        guard activeOperationID != id, let index = drafts.firstIndex(where: { $0.id == id }), !drafts[index].prepared else { return }
        change(&drafts[index]); drafts[index].updatedAt = Date()
        let snapshot = drafts[index]
        autosave?.cancel()
        autosave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                guard let self, let draftStore = self.draftStore else { return }
                try await draftStore.save(snapshot)
            } catch is CancellationError { }
            catch { self?.storageError = ghCollabText("草稿暂未保存，请重试。", "This draft has not been saved. Retry.") }
        }
    }
    func flushDraft(_ id: UUID) async {
        autosave?.cancel(); autosave = nil
        guard let draft = drafts.first(where: { $0.id == id }), let draftStore else { return }
        do { try await draftStore.save(draft); storageError = nil }
        catch { storageError = ghCollabText("草稿暂未保存，请重试。", "This draft has not been saved. Retry.") }
    }
    func removeDraft(_ id: UUID) async {
        guard activeOperationID != id, let draftStore,
              !records.contains(where: { $0.id == id && ($0.state == .unknown || $0.state == .sending) }) else { return }
        do {
            try await draftStore.remove(id); drafts.removeAll { $0.id == id }
            if draftRoute?.id == id { draftRoute = nil }
        } catch { operationError = message(error) }
    }
    func copyDraftForEditing(_ id: UUID) async {
        guard let original = drafts.first(where: { $0.id == id }), let draftStore,
              records.first(where: { $0.id == id }).map({ $0.state == .prepared || $0.state == .rejected }) == true else { return }
        do {
            let copy = original.editableCopy()
            try await draftStore.save(copy); drafts = try await draftStore.load(); draftRoute = .init(id: copy.id)
        } catch { operationError = message(error) }
    }
    func sendDraft(_ id: UUID) {
        guard activeOperationID == nil, reconcilingID == nil, canWrite else { return }
        activeOperationID = id; operationError = nil
        // This retained operation does not belong to a sheet's task lifetime.
        // Closing/rebuilding the view never creates a new send or request ID.
        operationTask = Task { [self] in
            defer { activeOperationID = nil; operationTask = nil }
            do {
                guard let owner = scope.ownerID, let draftStore,
                      var draft = drafts.first(where: { $0.id == id }), draft.scope == scope else {
                    throw GitHubCollaborationError.operationMismatch
                }
                try authorize()
                let currentRecords = await service.recent(ownerTaskID: owner)
                if draft.prepared, !currentRecords.contains(where: { $0.id == id }) {
                    throw GitHubCollaborationError.operationMismatch
                }
                let request = try preparedRequest(draft)
                _ = try await service.prepare(request, ownerTaskID: owner)
                draft.prepared = true; draft.updatedAt = Date()
                autosave?.cancel(); autosave = nil
                try await draftStore.save(draft)
                if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index] = draft }
                await refreshRecords()
                let token = try sendToken()
                _ = try await service.execute(id: id, ownerTaskID: owner, token: token, authorize: authorize)
                await refreshRecords()
                await loadList()
                if selection?.number == draft.number { await loadDetail() }
            } catch {
                await refreshRecords(); operationError = message(error)
            }
        }
    }
    func reconcile(_ id: UUID) async {
        guard activeOperationID == nil, reconcilingID == nil, let owner = scope.ownerID else { return }
        reconcilingID = id; operationError = nil
        defer { reconcilingID = nil }
        do {
            // Only the same recorded operation and authenticated account are
            // checked. The service never turns a missing readback into a POST.
            _ = try await service.reconcile(id: id, ownerTaskID: owner, token: sendToken())
            await refreshRecords()
        } catch { await refreshRecords(); operationError = message(error) }
    }
    func preparedRequest(_ draft: GitHubCollaborationDraft) throws -> GitHubPreparedMutation {
        try draft.validate()
        guard draft.scope == scope, let owner = scope.ownerID else { throw GitHubCollaborationError.operationMismatch }
        func number() throws -> Int {
            guard let n = draft.number, n > 0 else { throw GitHubCollaborationError.invalidInput("number") }; return n
        }
        func head() throws -> String {
            guard let value = draft.headSHA else { throw GitHubCollaborationError.invalidInput("head") }; return value
        }
        switch draft.kind {
        case .createIssue: return try .issue(id: draft.id, ownerTaskID: owner, repository: scope.repository, title: draft.title, body: draft.body)
        case .updateIssue: return try .issueState(id: draft.id, ownerTaskID: owner, repository: scope.repository, number: number(), closed: draft.closeIssue)
        case .reply: return try .reply(id: draft.id, ownerTaskID: owner, repository: scope.repository, number: number(), body: draft.body)
        case .createPull:
            let source = draft.headRepository ?? scope.repository
            let qualified = source == scope.repository ? draft.head : source.owner + ":" + draft.head
            return try .pull(id: draft.id, ownerTaskID: owner, repository: scope.repository,
                title: draft.title, body: draft.body, head: qualified, base: draft.base, headSHA: head(), draft: draft.draftPull,
                headRepository: source == scope.repository ? nil : source.name)
        case .review: return try .review(id: draft.id, ownerTaskID: owner, repository: scope.repository, number: number(), headSHA: head(), event: draft.reviewEvent, body: draft.body)
        case .lineComment:
            guard let line = draft.reviewLine else { throw GitHubCollaborationError.invalidLine }
            return try .lineComment(id: draft.id, ownerTaskID: owner, repository: scope.repository, number: number(), headSHA: head(), line: line, body: draft.body)
        case .mergePull: return try .merge(id: draft.id, ownerTaskID: owner, repository: scope.repository, number: number(), headSHA: head(), method: draft.mergeMethod)
        case .rerunActions, .rerunFailedActions, .cancelActions:
            guard let run = draft.actionRun else { throw GitHubCollaborationError.invalidInput("run") }
            if draft.kind == .cancelActions {
                return try .cancelRun(id: draft.id, ownerTaskID: owner, repository: scope.repository, runID: run.id, attempt: run.runAttempt, headSHA: run.headSHA)
            }
            return try .rerun(id: draft.id, ownerTaskID: owner, repository: scope.repository,
                runID: run.id, attempt: run.runAttempt, headSHA: run.headSHA, failedOnly: draft.kind == .rerunFailedActions)
        }
    }
    func loadBranches(for draftID: UUID, moreHead: Bool = false, moreBase: Bool = false) async {
        guard let draft = drafts.first(where: { $0.id == draftID }), draft.kind == .createPull, !draft.prepared else { return }
        branchGeneration += 1; let generation = branchGeneration
        branchesLoading = true
        defer { if generation == branchGeneration { branchesLoading = false } }
        do {
            let token = try readToken(), source = draft.headRepository ?? scope.repository
            if moreHead {
                guard let page = headNextPage else { return }
                let value = try await client.branches(source, page: page, token: token)
                guard generation == branchGeneration, !Task.isCancelled else { return }
                headBranches = unique(headBranches + value.items); headNextPage = value.nextPage
                return
            }
            if moreBase {
                guard let page = baseNextPage else { return }
                let value = try await client.branches(scope.repository, page: page, token: token)
                guard generation == branchGeneration, !Task.isCancelled else { return }
                baseBranches = unique(baseBranches + value.items); baseNextPage = value.nextPage
                return
            }
            async let heads = client.branches(source, page: 1, token: token)
            async let bases = client.branches(scope.repository, page: 1, token: token)
            async let defaultBranch = client.defaultBranch(scope.repository, token: token)
            let values = try await (heads, bases, defaultBranch)
            guard generation == branchGeneration, !Task.isCancelled,
                  drafts.first(where: { $0.id == draftID })?.headRepository == draft.headRepository else { return }
            headBranches = values.0.items; baseBranches = values.1.items
            headNextPage = values.0.nextPage; baseNextPage = values.1.nextPage
            // A real default branch may be beyond page one. Resolve it rather
            // than silently substituting the first alphabetic branch.
            let neededBase = draft.base.isEmpty ? values.2 : draft.base
            if !baseBranches.contains(where: { $0.name == neededBase }) {
                let actual = try await client.branch(scope.repository, name: neededBase, token: token)
                guard generation == branchGeneration, !Task.isCancelled else { return }
                baseBranches.insert(actual, at: 0)
            }
            if !draft.head.isEmpty, !headBranches.contains(where: { $0.name == draft.head }) {
                let actual = try await client.branch(source, name: draft.head, token: token)
                guard generation == branchGeneration, !Task.isCancelled else { return }
                headBranches.insert(actual, at: 0)
            }
            if drafts.first(where: { $0.id == draftID })?.base.isEmpty == true { updateDraft(draftID) { $0.base = values.2 } }
        } catch { if generation == branchGeneration, !Task.isCancelled { operationError = message(error) } }
    }
    func selectHead(_ name: String, draftID: UUID) {
        guard let branch = headBranches.first(where: { $0.name == name }) else { return }
        updateDraft(draftID) { $0.head = branch.name; $0.headSHA = branch.commit.sha }
    }
    func refreshDraftHead(_ id: UUID) async {
        guard let draft = drafts.first(where: { $0.id == id }), !draft.prepared,
              draft.kind == .review || draft.kind == .mergePull || draft.kind == .createPull else { return }
        do {
            let token = try readToken(), sha: String
            if draft.kind == .createPull {
                sha = try await client.branch(draft.headRepository ?? scope.repository, name: draft.head, token: token).commit.sha
            } else {
                guard let number = draft.number else { return }
                sha = try await client.pull(scope.repository, number: number, token: token).head.sha
            }
            guard let current = drafts.first(where: { $0.id == id }), !current.prepared,
                  current.head == draft.head, current.headRepository == draft.headRepository,
                  current.number == draft.number else { return }
            updateDraft(id) { $0.headSHA = sha }
        } catch { operationError = message(error) }
    }
    func changeHeadRepository(_ input: String, draftID: UUID) async {
        do {
            let url = input.hasPrefix("https://") ? input : "https://github.com/" + input
            let link = try GitHubLinkParser.parse(url)
            guard link.kind == .repository else { throw GitHubCollaborationError.invalidInput("repository") }
            updateDraft(draftID) { $0.headRepository = link.repository; $0.head = ""; $0.headSHA = nil }
            headBranches = []; await loadBranches(for: draftID)
        } catch { operationError = message(error) }
    }
    func inspectAction(_ url: URL) async {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.scheme?.lowercased() == "https", ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              parts.count >= 5, parts[0].caseInsensitiveCompare(scope.repository.owner) == .orderedSame,
              parts[1].caseInsensitiveCompare(scope.repository.name) == .orderedSame,
              parts[2] == "actions", parts[3] == "runs", let id = Int64(parts[4]), id > 0 else {
            detailError = ghCollabText("请输入此仓库的 GitHub Actions 运行链接。", "Enter a GitHub Actions run URL for this repository.")
            return
        }
        let generation = detailGeneration, head = pull?.head.sha
        do {
            let run = try await client.actionAttempt(scope.repository, runID: id, token: readToken())
            guard generation == detailGeneration, !Task.isCancelled else { return }
            if let head, run.headSHA != head { throw GitHubLinkError.sourceChanged }
            actionRun = run
        } catch { if generation == detailGeneration { detailError = message(error) } }
    }
}
#endif

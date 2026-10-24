// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace
import FloeGit

/// Native Git/Actions operations behind the EXISTING conversation-owned
/// workspace facade. Native stores resolve the root; payloads never supply it.
actor G04WorkspaceGit {
    enum Failure: Error, Sendable { case invalidArguments, needsAccount, pathRefused, unsupportedAction, jobsUnavailable }
    private let access: any G04WorkspaceAccessPort
    private let credentials: GitHubCredentialStore
    let git = LocalGitService()
    let github = GitHubService()
    private let actions = GitHubActionsClient()
    private let epoch: UInt64
    private var retired = false
    typealias DispatchJobPort = @Sendable (G04WorkspaceOwner, [String: SettingsDomainV1.JSONValue], CancellationToken) async throws -> DesignJSONValue
    private var dispatchJob: DispatchJobPort?
    func bindDispatchJobs(_ port: @escaping DispatchJobPort) throws {
        guard !retired else { throw G04DocumentError.retired }
        dispatchJob = port
    }
    /// The ORIGINAL durable Actions engine composition (GitHubActionsJobEngine
    /// + file-backed job store + reviewed policy ports in this module), bound
    /// per accepted generation to THIS Git actor's seams. Dispatch, refresh,
    /// cancel, jobs/logs/artifacts and verified streaming downloads run
    /// through it; there is no raw unowned Actions HTTP dispatch path. The
    /// engine is constructed here and bound via `bindDispatchJobs` — the
    /// previously incomplete connection this lane closes.
    let actionsDomain: G04GitActionsDomain

    init(epoch: UInt64, installed: G02InstalledComposition, access: any G04WorkspaceAccessPort) {
        self.epoch = epoch; self.access = access
        self.credentials = GitHubCredentialStore(lease: G04GitCredentialLease(epoch: epoch, installed: installed))
        self.actionsDomain = G04GitActionsDomain(epoch: epoch, installed: installed, access: access,
                                                 credentials: credentials)
        G04GitActionsRegistry.register(epoch: epoch, domain: actionsDomain)
        // Dispatch acknowledgement/association goes through the durable
        // engine BEFORE any remote side effect; default remains typed
        // jobsUnavailable until this bind settles (it is part of init).
        // Swift 6: actor `init` is nonisolated, so the isolated
        // `bindDispatchJobs` guard (retired == false here by construction)
        // cannot run; the bind is the same stored-port assignment it would
        // make, applied directly to self's own stored property.
        dispatchJob = actionsDomain.dispatchPort
    }

    func execute(owner: G04WorkspaceOwner, action: String,
                 arguments: [String: SettingsDomainV1.JSONValue], write: Bool,
                 documents: G04WorkspaceDocumentSession) async throws -> DesignJSONValue {
        guard !retired, owner.epoch == epoch else { throw G04DocumentError.retired }
        let args = try Arguments(action: action, values: arguments, write: write)
        let lease = try await access.acquire(owner: owner, intent: write ? .fileMutation : .read, relativePath: nil)
        var mutation: UUID?
        do {
            try lease.cancellation.throwIfCancelled()
            guard !retired else { throw G04DocumentError.retired }
            let root = lease.service.guardResolver.rootURL
            try G04GitMetadataBoundary.validate(root: root)
            if Self.workingTreeWriters.contains(action) { mutation = try await documents.beginExternalMutation() }
            let result: DesignJSONValue
            if action == "actions.dispatch" {
                // Dispatch acknowledgement/association belongs to the
                // original durable job service, not a cancellable UI call.
                guard let dispatchJob else { throw Failure.jobsUnavailable }
                result = try await dispatchJob(owner, arguments, lease.cancellation)
            } else if G04GitActionsDomain.engineActions.contains(action) {
                // Preview/records/refresh/jobs/logs/artifacts/cancel/streaming
                // download/install run through the durable engine composition
                // under this same accepted lease + ownership chain.
                result = try await actionsDomain.handle(action: action, args: args, owner: owner,
                    root: root, service: lease.service, cancellation: lease.cancellation)
            } else {
                result = try await perform(action: action, args: args, root: root,
                    guardResolver: lease.service.guardResolver, cancellation: lease.cancellation)
            }
            var unavailable: [String] = []
            if let token = mutation {
                unavailable = try await documents.finishExternalMutation(token, service: lease.service)
                mutation = nil
            }
            try lease.cancellation.throwIfCancelled()
            guard !retired, G02NativeRootEpoch.readback() == epoch else { throw G04DocumentError.retired }
            await lease.release()
            return .object(["action": .string(action), "value": result,
                "editorRefreshUnavailable": .array(unavailable.map { .string($0) })])
        } catch {
            if let token = mutation { _ = try? await documents.finishExternalMutation(token, service: lease.service) }
            await lease.release()
            throw error
        }
    }

    /// Working-tree writers plus `actions.dispatch`: the document mutation
    /// barrier refuses dirty native drafts before dispatch so the reviewed
    /// snapshot published to GitHub is the ACTUAL disk truth the editor
    /// shows, and re-reads afterwards. Dispatch itself never edits tracked
    /// files; the barrier here is the freshness gate, not a write lock.
    static let workingTreeWriters: Set<String> = ["switchBranch", "merge", "resolveConflict", "abortMerge", "discard", "pull", "pullMerge", "actions.dispatch"]
    func retire() {
        retired = true
        G04GitCredentialLease.reconcilePending(epoch: epoch)
        G04GitActionsRegistry.deregister(epoch: epoch)
        // Stops only the LOCAL pollers. Durable records remain queryable and
        // the next generation re-queries the real remote state honestly.
        Task { await actionsDomain.retire() }
    }

    private func perform(action: String, args: Arguments, root: URL,
                         guardResolver: WorkspacePathGuard,
                         cancellation: CancellationToken) async throws -> DesignJSONValue {
        func encoded<T: Encodable>(_ value: T) throws -> DesignJSONValue {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return try JSONDecoder().decode(DesignJSONValue.self, from: encoder.encode(value))
        }
        func checkedPaths() throws -> [String] {
            let paths = try args.paths()
            for path in paths { _ = try guardResolver.resolve(path) }
            return paths
        }
        func accountToken() async throws -> String {
            try cancellation.throwIfCancelled()
            guard let token = try await credentials.token() else { throw Failure.needsAccount }
            try cancellation.throwIfCancelled()
            return token
        }
        func author() throws -> (String, String) {
            (try args.optional("authorName", maximum: 800) ?? "Floe",
             try args.optional("authorEmail", maximum: 800) ?? "floe@local.floeagent")
        }
        switch action {
        case "snapshot":
            // Never discover a parent repository outside this selected task.
            guard await git.repositoryRoot(at: root, ownershipBoundary: root) != nil else {
                return try encoded(GitRepositorySnapshot(isRepository: false))
            }
            return try encoded(await git.snapshot(at: root, commitLimit: 50))
        case "diff", "diffStaged":
            let path = try args.optional("path")
            if let path { _ = try guardResolver.resolve(path) }
            let text = try await (action == "diff" ? git.diff(at: root, path: path) : git.diffStaged(at: root, path: path))
            return .object(["text": .string(text)])
        case "initialize":
            let identity = try author()
            return try encoded(await git.initialize(at: root, authorName: identity.0,
                authorEmail: identity.1, initialBranch: try args.optional("branch", maximum: 200) ?? "main"))
        case "stage":
            let paths = try checkedPaths()
            if paths.isEmpty { try await git.stageAll(at: root) }
            else { try await git.stage(paths: paths, at: root) }
        case "unstage": try await git.unstage(paths: checkedPaths(), at: root)
        case "discard":
            return try encoded(await git.discard(paths: checkedPaths(), at: root,
                                                 includeStaged: args.flag("includeStaged")))
        case "commit":
            let identity = try author()
            return try encoded(await git.commit(at: root, message: args.text("message", maximum: 8192),
                                                 authorName: identity.0, authorEmail: identity.1))
        case "createBranch": try await git.createBranch(at: root, name: args.text("name", maximum: 200))
        case "switchBranch": try await git.switchBranch(at: root, name: args.text("name", maximum: 200))
        case "isMerging": return .object(["merging": .bool(try await git.isMerging(at: root))])
        case "merge":
            let identity = try author()
            return try encoded(await git.mergeRef(at: root, refName: args.text("reference", maximum: 512),
                                                   authorName: identity.0, authorEmail: identity.1))
        case "resolveConflict":
            let identity = try author(); let path = try args.text("path")
            _ = try guardResolver.resolve(path)
            return try encoded(await git.resolveConflict(at: root, path: path,
                content: args.text("content", maximum: 32 * 1024), authorName: identity.0, authorEmail: identity.1))
        case "abortMerge": try await git.abortMerge(at: root)
        case "fetch": try await git.fetch(at: root, token: credentials.token())
        case "push": try await git.push(at: root, token: accountToken())
        case "pull": try await git.pullFastForward(at: root, token: credentials.token())
        case "pullMerge":
            let identity = try author()
            return try encoded(await git.pullMerge(at: root, token: credentials.token(),
                                                   authorName: identity.0, authorEmail: identity.1))
        case "clone":
            let path = try args.text("destination")
            let target = try guardResolver.resolve(path)
            guard target != root, let remote = URL(string: try args.text("remoteURL", maximum: 4096)) else {
                throw Failure.invalidArguments
            }
            try await git.clone(from: remote, to: target, token: credentials.token())
            return .object(["path": .string(path)])
        case "account": return try encoded(await github.account(token: accountToken()))
        case "repositories": return try encoded(await github.repositories(token: accountToken(), limit: 100))
        case "createRepository":
            return try encoded(await github.createRepository(token: accountToken(), name: args.text("name", maximum: 200),
                isPrivate: args.flag("private"), description: args.optional("description", maximum: 4096)))
        case "actions.workflows", "actions.runs", "actions.run", "actions.jobs", "actions.artifacts", "actions.cancel":
            let owner = try args.segment("owner"); let repository = try args.segment("repository")
            let token = try await accountToken()
            switch action {
            case "actions.workflows": return try encoded(await actions.workflows(owner: owner, repository: repository, token: token))
            case "actions.runs": return try encoded(await actions.workflowRuns(owner: owner, repository: repository,
                workflowID: args.number("workflowID"), token: token, branch: args.optional("branch"), maxPages: 3))
            case "actions.run": return try encoded(await actions.run(owner: owner, repository: repository,
                runID: args.number("runID"), token: token))
            case "actions.jobs": return try encoded(await actions.jobs(owner: owner, repository: repository,
                runID: args.number("runID"), token: token))
            case "actions.artifacts": return try encoded(await actions.artifacts(owner: owner, repository: repository,
                runID: args.number("runID"), token: token))
            case "actions.cancel":
                try await actions.cancelRun(owner: owner, repository: repository,
                    runID: args.number("runID"), token: token)
                return .object(["requested": .bool(true)])
            default: throw Failure.unsupportedAction
            }
        default: throw Failure.unsupportedAction
        }
        return .object(["completed": .bool(true)])
    }

    struct Arguments: Sendable {
        typealias Value = SettingsDomainV1.JSONValue
        let values: [String: Value]
        static let fields: [String: Set<String>] = [
            "snapshot": [], "diff": ["path"], "diffStaged": ["path"], "isMerging": [],
            "initialize": ["authorName", "authorEmail", "branch"], "stage": ["paths"], "unstage": ["paths"],
            "discard": ["paths", "includeStaged"], "commit": ["message", "authorName", "authorEmail"],
            "createBranch": ["name"], "switchBranch": ["name"], "merge": ["reference", "authorName", "authorEmail"],
            "resolveConflict": ["path", "content", "authorName", "authorEmail"], "abortMerge": [],
            "fetch": [], "push": [], "pull": [], "pullMerge": ["authorName", "authorEmail"],
            "clone": ["destination", "remoteURL"], "account": [], "repositories": [],
            "createRepository": ["name", "private", "description"],
            "actions.workflows": ["owner", "repository"], "actions.runs": ["owner", "repository", "workflowID", "branch"],
            "actions.run": ["owner", "repository", "runID"], "actions.jobs": ["owner", "repository", "runID"],
            "actions.artifacts": ["owner", "repository", "runID"], "actions.cancel": ["owner", "repository", "runID"],
            // Durable engine dispatch: reviewed-snapshot association is the
            // idempotent intent, NOT a raw (owner, workflowID, ref) trigger.
            "actions.dispatch": ["owner", "repository", "workflowPath", "requestID", "languageID",
                "role", "platform", "targetFile", "inputs", "reviewedManifestSHA"],
            "actions.snapshotPreview": ["directory"], "actions.templates": ["languageID"],
            "actions.records": [], "actions.record": ["recordID"], "actions.refresh": ["recordID"],
            "actions.jobLog": ["recordID", "jobID"], "actions.loadArtifacts": ["recordID"],
            "actions.downloadArtifact": ["recordID", "artifactID", "overwrite"],
            "actions.cancelJob": ["recordID"],
            "actions.installTemplate": ["owner", "repository", "templateID"],
        ]
        static let reads: Set<String> = ["snapshot", "diff", "diffStaged", "isMerging", "account", "repositories",
            "actions.workflows", "actions.runs", "actions.run", "actions.jobs", "actions.artifacts",
            "actions.snapshotPreview", "actions.templates", "actions.records", "actions.record",
            "actions.refresh", "actions.jobLog", "actions.loadArtifacts"]
        init(action: String, values: [String: Value], write: Bool) throws {
            guard let fields = Self.fields[action], Set(values.keys).isSubset(of: fields),
                  Self.reads.contains(action) != write else { throw Failure.invalidArguments }
            self.values = values
        }
        func text(_ key: String, maximum: Int = 4096) throws -> String {
            guard case .string(let value)? = values[key], !value.isEmpty,
                  value.utf8.count <= maximum, !value.contains("\0") else { throw Failure.invalidArguments }
            return value
        }
        func optional(_ key: String, maximum: Int = 4096) throws -> String? {
            guard let value = values[key], value != .null else { return nil }
            return try text(key, maximum: maximum)
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = values[key] else { return false }
            guard case .boolean(let result) = value else { throw Failure.invalidArguments }
            return result
        }
        func number(_ key: String) throws -> Int64 {
            guard case .integer(let value)? = values[key], value > 0 else { throw Failure.invalidArguments }
            return value
        }
        func segment(_ key: String) throws -> String {
            let value = try text(key, maximum: 200)
            guard value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || [45, 46, 95].contains($0) }), value != ".", value != ".." else {
                throw Failure.invalidArguments
            }
            return value
        }
        func paths() throws -> [String] {
            guard let value = values["paths"] else { return [] }
            guard case .array(let rows) = value, rows.count <= 200 else { throw Failure.invalidArguments }
            return try rows.map { row in
                guard case .string(let path) = row, !path.isEmpty, path.utf8.count <= 4096,
                      !path.contains("\0") else { throw Failure.invalidArguments }
                return path
            }
        }
        func stringMap(_ key: String) throws -> [String: String] {
            guard let value = values[key] else { return [:] }
            guard case .object(let fields) = value, fields.count <= 50 else { throw Failure.invalidArguments }
            var result: [String: String] = [:]
            for (name, value) in fields {
                guard name.utf8.count <= 200, case .string(let text) = value, text.utf8.count <= 4096 else {
                    throw Failure.invalidArguments
                }
                result[name] = text
            }
            return result
        }
    }
}

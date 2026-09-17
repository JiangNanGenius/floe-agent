import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsClient — the network half of the IDE's GitHub Actions target.
// It is a plain Sendable value over an injected `URLSession` and depends only
// on Foundation, so its request building, bounded reads, redirect handling and
// response decoding are exercised by URLProtocol fixtures in tests and by the
// local policy harness without the app or the Keychain.
//
// Security rules enforced here:
// * the bearer token is supplied per call and never stored on the value;
// * every response is size-bounded; oversized bodies fail with a typed error;
// * a signed artifact redirect strips `Authorization` before the request
//   leaves api.github.com, so the API token is never sent to blob storage;
// * error text is redacted against the token before it is surfaced.

public struct GitHubActionsClient: Sendable {
    public static let maximumJSONBytes = 4 * 1024 * 1024
    public static let maximumLogBytes = 512 * 1024
    public static let maximumArtifactBytes = 64 * 1024 * 1024

    public let session: URLSession
    public let baseURL: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.github.com/")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: URL construction

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private func escaped(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? segment
    }

    private func apiURL(_ segments: [String], query: [URLQueryItem] = []) throws -> URL {
        guard let url = URL(string: segments.map(escaped).joined(separator: "/"), relativeTo: baseURL),
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased() else {
            throw GitHubActionsError.invalidConfiguration("invalid GitHub API path")
        }
        guard !query.isEmpty else { return url }
        // `URL(string:relativeTo:)` stores the base in `baseURL`; `URLComponents`
        // with `resolvingAgainstBaseURL: false` reads only the relative portion
        // and would emit a scheme-less URL, which URLSession rejects as an
        // "unsupported URL". Resolve to the absolute URL first so the composed
        // query URL keeps https://api.github.com before it reaches the network.
        var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let composed = components?.url,
              composed.scheme?.lowercased() == "https",
              composed.host?.lowercased() == baseURL.host?.lowercased() else {
            throw GitHubActionsError.invalidConfiguration("invalid GitHub API query")
        }
        return composed
    }

    private func request(
        _ url: URL, method: String, token: String, body: Data?, accept: String,
        apiVersion: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    // MARK: Transport

    private struct ErrorPayload: Decodable { let message: String? }

    private func send(
        _ url: URL, method: String, token: String, body: Data? = nil,
        accept: String = "application/vnd.github+json",
        maxBytes: Int = maximumJSONBytes, apiVersion: String = Self.stableAPIVersion
    ) async throws -> (Data, HTTPURLResponse) {
        let request = request(
            url, method: method, token: token, body: body, accept: accept,
            apiVersion: apiVersion
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubActionsError.transport(redact(error.localizedDescription, token: token))
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubActionsError.transport("GitHub did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? Self.decoder.decode(ErrorPayload.self, from: data))?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubActionsError.http(
                status: http.statusCode,
                message: redact(String(message.prefix(512)), token: token)
            )
        }
        guard data.count <= maxBytes else { throw GitHubActionsError.responseTooLarge(limit: maxBytes) }
        return (data, http)
    }

    /// Decodes a JSON body into `T`. `T` may be an array or a page envelope.
    private func getJSON<T: Decodable>(
        _ url: URL, token: String, maxBytes: Int = maximumJSONBytes
    ) async throws -> T {
        let (data, _) = try await send(url, method: "GET", token: token, maxBytes: maxBytes)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw GitHubActionsError.decoding(String(describing: T.self)) }
    }

    /// Walks `Link`-header pages up to `GitHubActionsPagination.maximumPages`.
    private func getPaged<Item: Decodable>(
        _ firstURL: URL, token: String, pageKey: String, maxPages: Int
    ) async throws -> [Item] {
        var results: [Item] = []
        var url: URL? = firstURL
        var pageCount = 0
        while let current = url, pageCount < min(max(maxPages, 1), GitHubActionsPagination.maximumPages) {
            let (data, http) = try await send(
                current, method: "GET", token: token, maxBytes: Self.maximumJSONBytes
            )
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let container = object as? [String: Any],
                  let rawItems = container[pageKey] as? [Any],
                  let itemsData = try? JSONSerialization.data(withJSONObject: rawItems),
                  let decoded = try? Self.decoder.decode([Item].self, from: itemsData) else {
                throw GitHubActionsError.decoding(pageKey)
            }
            results.append(contentsOf: decoded)
            pageCount += 1
            let header = http.value(forHTTPHeaderField: "Link")
            if let next = GitHubActionsPagination.nextURL(fromLinkHeader: header),
               GitHubActionsPagination.isFollowable(next: next, origin: baseURL) {
                url = next
            } else {
                url = nil
            }
        }
        return results
    }

    // MARK: Workflows and runs

    private struct WorkflowsEnvelope: Decodable { let workflows: [GitHubActionsWorkflow] }
    private struct RunsEnvelope: Decodable { let workflow_runs: [GitHubActionsRun] }
    private struct JobsEnvelope: Decodable { let jobs: [GitHubActionsJob] }
    private struct ArtifactsEnvelope: Decodable { let artifacts: [GitHubActionsArtifact] }

    public func workflows(owner: String, repository: String, token: String) async throws -> [GitHubActionsWorkflow] {
        let url = try apiURL(
            ["repos", owner, repository, "actions", "workflows"],
            query: [URLQueryItem(name: "per_page", value: String(GitHubActionsPagination.maximumPerPage))]
        )
        return try await getPaged(url, token: token, pageKey: "workflows", maxPages: 1)
    }

    /// Lists the workflow files that actually exist on `ref`. Used to offer a
    /// choice of the user's own workflow instead of injecting a template.
    public func workflowFilePaths(owner: String, repository: String, ref: String, token: String) async throws -> [String] {
        struct Entry: Decodable { let path: String; let type: String }
        let url = try apiURL(
            ["repos", owner, repository, "contents", ".github", "workflows"],
            query: [URLQueryItem(name: "ref", value: ref)]
        )
        do {
            let entries: [Entry] = try await getJSON(url, token: token)
            return entries.filter { $0.type == "file" }.map(\.path).sorted()
        } catch GitHubActionsError.http(let status, _) where status == 404 {
            // No workflows directory on this ref is a legitimate empty answer.
            return []
        }
    }

    /// Reads one repository file's raw bytes at `ref`. `nil` means the path
    /// does not exist there, which is how the workflow-install policy proves a
    /// Floe template can be added without overwriting a user's file. Only
    /// regular files are expected; a directory/other answer is an error.
    public func fileContent(
        owner: String, repository: String, path: String, ref: String, token: String,
        maxBytes: Int = 1 * 1024 * 1024
    ) async throws -> Data? {
        let segments = ["repos", owner, repository, "contents"]
            + path.split(separator: "/").map(String.init)
        let url = try apiURL(segments, query: [URLQueryItem(name: "ref", value: ref)])
        do {
            let (data, _) = try await send(
                url, method: "GET", token: token,
                accept: "application/vnd.github.raw+json", maxBytes: maxBytes
            )
            return data
        } catch GitHubActionsError.http(let status, _) where status == 404 {
            return nil
        }
    }

    /// Fast-forwards a branch ref to `sha` with `force: false`, so GitHub
    /// refuses a non-fast-forward update instead of clobbering a user branch.
    /// Used only to install a Floe workflow file on the repository's default
    /// branch, because `workflow_dispatch` cannot discover a workflow that
    /// exists only on another branch.
    public func updateRef(
        owner: String, repository: String, branch: String, sha: String, token: String
    ) async throws {
        let url = try apiURL(["repos", owner, repository, "git", "refs", "heads", branch])
        let body = try JSONSerialization.data(withJSONObject: ["sha": sha, "force": false])
        _ = try await send(url, method: "PATCH", token: token, body: body)
    }

    public func workflowRuns(
        owner: String, repository: String, workflowID: Int64, token: String,
        branch: String? = nil, event: String? = nil, maxPages: Int = 1
    ) async throws -> [GitHubActionsRun] {
        var query = [URLQueryItem(name: "per_page", value: String(GitHubActionsPagination.maximumPerPage))]
        if let branch { query.append(URLQueryItem(name: "branch", value: branch)) }
        if let event { query.append(URLQueryItem(name: "event", value: event)) }
        let url = try apiURL(
            ["repos", owner, repository, "actions", "workflows", String(workflowID), "runs"],
            query: query
        )
        return try await getPaged(url, token: token, pageKey: "workflow_runs", maxPages: maxPages)
    }

    public func run(owner: String, repository: String, runID: Int64, token: String) async throws -> GitHubActionsRun {
        let url = try apiURL(["repos", owner, repository, "actions", "runs", String(runID)])
        return try await getJSON(url, token: token)
    }

    public func jobs(owner: String, repository: String, runID: Int64, token: String, maxPages: Int = 3) async throws -> [GitHubActionsJob] {
        let url = try apiURL(
            ["repos", owner, repository, "actions", "runs", String(runID), "jobs"],
            query: [URLQueryItem(name: "per_page", value: String(GitHubActionsPagination.maximumPerPage))]
        )
        return try await getPaged(url, token: token, pageKey: "jobs", maxPages: maxPages)
    }

    public func artifacts(owner: String, repository: String, runID: Int64, token: String, maxPages: Int = 3) async throws -> [GitHubActionsArtifact] {
        let url = try apiURL(
            ["repos", owner, repository, "actions", "runs", String(runID), "artifacts"],
            query: [URLQueryItem(name: "per_page", value: String(GitHubActionsPagination.maximumPerPage))]
        )
        return try await getPaged(url, token: token, pageKey: "artifacts", maxPages: maxPages)
    }

    // MARK: Dispatch

    private struct DispatchResponse: Decodable {
        let workflow_run_id: Int64?
        let run_url: String?
        let html_url: String?
    }

    /// The API version pinned for ordinary endpoints.
    public static let stableAPIVersion = "2022-11-28"
    /// The dispatch endpoint returns a run id and URLs on the newer API
    /// version. Older deployments answer `204` with an empty body; both are
    /// accepted explicitly rather than assumed.
    public static let workflowDispatchAPIVersion = "2026-03-10"

    /// Result of a dispatch trigger. `runID` is present on the newer API; nil
    /// on a legacy `204`, in which case the caller associates by snapshot.
    public struct GitHubActionsTriggerResult: Sendable, Equatable {
        public let runID: Int64?
        public let runURL: URL?
        public let htmlURL: URL?
        public let acknowledgedWithoutBody: Bool

        public init(runID: Int64?, runURL: URL?, htmlURL: URL?, acknowledgedWithoutBody: Bool) {
            self.runID = runID; self.runURL = runURL; self.htmlURL = htmlURL
            self.acknowledgedWithoutBody = acknowledgedWithoutBody
        }
    }

    /// Baseline of run ids observed before a dispatch. Persisting this before
    /// the trigger lets a relaunch prove whether the trigger produced a run
    /// instead of blindly dispatching again.
    public struct GitHubActionsDispatchBaseline: Sendable, Equatable {
        public let runIDs: Set<Int64>
        public let capturedAt: Date

        public init(runIDs: Set<Int64>, capturedAt: Date) {
            self.runIDs = runIDs; self.capturedAt = capturedAt
        }
    }

    /// Captures the run ids that already exist for this workflow/ref/event.
    public func dispatchBaseline(
        owner: String, repository: String, workflowID: Int64, branch: String,
        token: String, now: Date = Date()
    ) async throws -> GitHubActionsDispatchBaseline {
        let runs = try await workflowRuns(
            owner: owner, repository: repository, workflowID: workflowID,
            token: token, branch: branch, event: "workflow_dispatch", maxPages: 1
        )
        return GitHubActionsDispatchBaseline(runIDs: Set(runs.map(\.id)), capturedAt: now)
    }

    /// Triggers `workflow_dispatch`. Accepts both documented shapes: a `200`
    /// JSON body carrying `workflow_run_id` (+ `run_url`/`html_url`) and a
    /// legacy `204` empty body. Never invents a run id.
    public func triggerDispatch(
        owner: String, repository: String, workflowID: Int64, ref: String,
        inputs: [String: String], token: String
    ) async throws -> GitHubActionsTriggerResult {
        let body = try JSONSerialization.data(withJSONObject: ["ref": ref, "inputs": inputs])
        let url = try apiURL(["repos", owner, repository, "actions", "workflows", String(workflowID), "dispatches"])
        let (data, _) = try await send(
            url, method: "POST", token: token, body: body,
            apiVersion: Self.workflowDispatchAPIVersion
        )
        guard !data.isEmpty,
              let decoded = try? Self.decoder.decode(DispatchResponse.self, from: data) else {
            // Explicit legacy 204 / empty acknowledgement.
            return GitHubActionsTriggerResult(
                runID: nil, runURL: nil, htmlURL: nil, acknowledgedWithoutBody: true
            )
        }
        return GitHubActionsTriggerResult(
            runID: decoded.workflow_run_id,
            runURL: decoded.run_url.flatMap(URL.init(string:)),
            htmlURL: decoded.html_url.flatMap(URL.init(string:)),
            acknowledgedWithoutBody: decoded.workflow_run_id == nil
        )
    }

    /// Composed convenience: capture baseline, trigger, build the receipt.
    /// The center uses the split calls so the baseline is persisted before the
    /// trigger; this remains for callers that do not need that durability.
    public func dispatchWorkflow(
        owner: String, repository: String, workflowID: Int64, ref: String,
        headSHA: String, inputs: [String: String], token: String,
        now: Date = Date()
    ) async throws -> GitHubActionsDispatchReceipt {
        let baseline = try await dispatchBaseline(
            owner: owner, repository: repository, workflowID: workflowID,
            branch: ref, token: token, now: now
        )
        let trigger = try await triggerDispatch(
            owner: owner, repository: repository, workflowID: workflowID,
            ref: ref, inputs: inputs, token: token
        )
        return GitHubActionsDispatchReceipt(
            owner: owner, repository: repository, workflowID: workflowID, ref: ref,
            headSHA: headSHA, dispatchedAt: baseline.capturedAt,
            baselineRunIDs: baseline.runIDs, returnedRunID: trigger.runID
        )
    }

    /// Bounded backoff hint for rate-limit / secondary-limit responses so the
    /// caller never hot-loops against GitHub.
    public static func isRateLimited(_ error: Error) -> Bool {
        if case GitHubActionsError.http(let status, let message) = error {
            if status == 429 { return true }
            if status == 403, message.lowercased().contains("rate limit") { return true }
        }
        return false
    }

    /// Polls for the unique run created by `receipt`. Returns the associated
    /// run or throws `associationUnresolved`.
    ///
    /// When GitHub's dispatch response returned an explicit run id, that id is
    /// read directly (`GET /actions/runs/{id}`) and validated against the full
    /// receipt identity; the id is authoritative for *which* object, but a run
    /// with the wrong workflow/snapshot/ref/event/baseline is refused. A `404`
    /// is treated as "not visible yet" (read-replica lag) and retried within
    /// the same bound. The workflow list endpoint is consulted only when no run
    /// id is known (a legacy `204` acknowledgement), where the snapshot
    /// identity selects the unique run. `maxAttempts`/`pollInterval` keep the
    /// wait bounded; a reused run id can never be adopted, and a lost run id
    /// never causes a second dispatch.
    public func associateRun(
        _ receipt: GitHubActionsDispatchReceipt, token: String,
        maxAttempts: Int = 10, pollInterval: TimeInterval = 3
    ) async throws -> GitHubActionsRun {
        var attempt = 0
        var lastFailure = GitHubActionsAssociationFailure.notFound
        while attempt < max(maxAttempts, 1) {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(Int(max(pollInterval, 0) * 1000)))
            }
            attempt += 1
            if let returnedRunID = receipt.returnedRunID {
                switch try await fetchReturnedRunIfVisible(
                    receipt: receipt, runID: returnedRunID, token: token
                ) {
                case .visible(let run):
                    // GitHub's returned id selects the object. The existing
                    // selector still proves the full snapshot identity (its
                    // returned-id branch is bypassed), so a reachable object
                    // with the wrong identity is refused rather than adopted.
                    guard let validated = validatedReturnedRun(run, receipt: receipt) else {
                        throw GitHubActionsError.associationUnresolved(
                            "GitHub returned run \(returnedRunID), but it does not carry "
                            + "snapshot \(String(receipt.headSHA.prefix(12))) on "
                            + "\(receipt.ref) for workflow \(receipt.workflowID); Floe did not adopt it."
                        )
                    }
                    return validated
                case .notVisible:
                    // The run id is known but the object is briefly 404 while
                    // GitHub catches up; retry within the bound.
                    lastFailure = .notFound
                }
            } else {
                let candidates = try await workflowRuns(
                    owner: receipt.owner, repository: receipt.repository,
                    workflowID: receipt.workflowID, token: token,
                    branch: receipt.ref, event: "workflow_dispatch", maxPages: 1
                )
                switch GitHubActionsRunAssociation.select(candidates: candidates, receipt: receipt) {
                case .success(let run): return run
                case .failure(let failure): lastFailure = failure
                }
            }
        }
        switch lastFailure {
        case .ambiguous(let ids):
            throw GitHubActionsError.associationUnresolved(
                "Multiple GitHub Actions runs matched this snapshot (\(ids.map(String.init).joined(separator: ", "))); Floe did not guess."
            )
        case .notFound:
            throw GitHubActionsError.associationUnresolved(
                "The workflow was dispatched, but no run carrying snapshot \(String(receipt.headSHA.prefix(12))) was found within the wait bound."
            )
        }
    }

    /// Whether a directly requested run id is already readable.
    private enum ReturnedRunVisibility {
        case visible(GitHubActionsRun)
        /// A `404`: the run may simply not have propagated to the read replica.
        case notVisible
    }

    /// Reads the run GitHub named in the dispatch response. Only a `404` is
    /// softened to `notVisible`; every other failure (auth, transport, decode)
    /// propagates so a real problem is never mistaken for indexing lag.
    private func fetchReturnedRunIfVisible(
        receipt: GitHubActionsDispatchReceipt, runID: Int64, token: String
    ) async throws -> ReturnedRunVisibility {
        do {
            let run = try await self.run(
                owner: receipt.owner, repository: receipt.repository,
                runID: runID, token: token
            )
            return .visible(run)
        } catch GitHubActionsError.http(let status, _) where status == 404 {
            return .notVisible
        }
    }

    /// Confirms a run read directly by the id GitHub returned. The id is
    /// authoritative for *which* object, but the run is only adopted when it
    /// also matches this dispatch on workflow, snapshot, ref, the
    /// `workflow_dispatch` event, the pre-dispatch baseline and the creation
    /// window. The snapshot checks reuse the existing
    /// `GitHubActionsRunAssociation.select` by passing the same run as the only
    /// candidate with the returned-id branch disabled; no second dispatch and
    /// no shared-decision API change are needed.
    private func validatedReturnedRun(
        _ run: GitHubActionsRun, receipt: GitHubActionsDispatchReceipt
    ) -> GitHubActionsRun? {
        guard run.id == receipt.returnedRunID, run.event == "workflow_dispatch" else { return nil }
        let snapshotReceipt = GitHubActionsDispatchReceipt(
            owner: receipt.owner, repository: receipt.repository,
            workflowID: receipt.workflowID, ref: receipt.ref, headSHA: receipt.headSHA,
            dispatchedAt: receipt.dispatchedAt, baselineRunIDs: receipt.baselineRunIDs,
            returnedRunID: nil
        )
        switch GitHubActionsRunAssociation.select(candidates: [run], receipt: snapshotReceipt) {
        case .success(let match): return match
        case .failure: return nil
        }
    }

    public func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws {
        let url = try apiURL(["repos", owner, repository, "actions", "runs", String(runID), "cancel"])
        _ = try await send(url, method: "POST", token: token)
    }

    // MARK: Logs

    /// Bounded text for one job. A log endpoint redirects to a signed file;
    /// the redirect guard strips the API token, and the reader stops at
    /// `maxBytes`.
    public func jobLog(
        owner: String, repository: String, jobID: Int64, token: String,
        maxBytes: Int = GitHubActionsClient.maximumLogBytes
    ) async throws -> GitHubActionsLogSlice {
        let url = try apiURL(["repos", owner, repository, "actions", "jobs", String(jobID), "logs"])
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        return try await boundedText(request, token: token, maxBytes: maxBytes)
    }

    /// Streams a text response and stops at `maxBytes`, so a huge log cannot
    /// allocate past the cap. `truncated` is set when the server had more.
    private func boundedText(_ request: URLRequest, token: String, maxBytes: Int) async throws -> GitHubActionsLogSlice {
        #if canImport(FoundationNetworking)
        // swift-corelibs transport: bounded fetch without truncation support.
        let data = try await download(request, token: token, maxBytes: maxBytes, expectedSize: nil)
        return GitHubActionsLogSlice(text: String(decoding: data, as: UTF8.self), truncated: false, byteCount: data.count)
        #else
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: GitHubActionsRedirectGuard())
        } catch {
            throw GitHubActionsError.transport(redact(error.localizedDescription, token: token))
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubActionsError.transport("GitHub did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubActionsError.http(
                status: http.statusCode,
                message: redact(HTTPURLResponse.localizedString(forStatusCode: http.statusCode), token: token)
            )
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        var truncated = false
        for try await byte in bytes {
            if data.count >= maxBytes { truncated = true; break }
            data.append(byte)
        }
        return GitHubActionsLogSlice(
            text: String(decoding: data, as: UTF8.self),
            truncated: truncated, byteCount: data.count
        )
        #endif
    }

    // MARK: Artifacts

    /// Downloads one artifact archive with a hard size cap. The caller
    /// verifies the SHA-256 and commits the bytes through the workspace path
    /// guard; this type only returns bytes and the final host.
    public func downloadArtifact(
        artifact: GitHubActionsArtifact, token: String,
        maxBytes: Int = GitHubActionsClient.maximumArtifactBytes
    ) async throws -> GitHubActionsArtifactDownload {
        if artifact.sizeInBytes > Int64(maxBytes) {
            throw GitHubActionsError.responseTooLarge(limit: maxBytes)
        }
        guard let archiveURL = artifact.archiveDownloadURL as URL?,
              archiveURL.scheme?.lowercased() == "https" else {
            throw GitHubActionsError.invalidConfiguration("artifact download URL must be HTTPS")
        }
        var request = URLRequest(url: archiveURL)
        request.timeoutInterval = 120
        // The bearer token is only attached when the archive URL is the same
        // API origin this client was configured with. A caller-supplied URL on
        // another host is fetched without the token (and the redirect guard
        // strips it if the response redirects again).
        if archiveURL.host?.lowercased() == baseURL.host?.lowercased() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        let data = try await download(request, token: token, maxBytes: maxBytes, expectedSize: Int(artifact.sizeInBytes))
        let host = artifact.archiveDownloadURL.host?.lowercased() ?? baseURL.host?.lowercased() ?? ""
        let safeName = artifact.name.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression
        )
        return GitHubActionsArtifactDownload(
            data: data,
            sourceHost: host,
            suggestedFileName: safeName.isEmpty ? "artifact-\(artifact.id).zip" : "\(safeName).zip"
        )
    }

    /// Fetches bytes, following signed redirects without the bearer token.
    /// A session-level guard delegate is installed for every platform so the
    /// token can never be forwarded to a blob-storage host, and any redirect
    /// to a non-HTTPS destination is refused.
    private func download(
        _ request: URLRequest, token: String, maxBytes: Int, expectedSize: Int?
    ) async throws -> Data {
        if let expectedSize, expectedSize > maxBytes {
            throw GitHubActionsError.responseTooLarge(limit: maxBytes)
        }
        let guardDelegate = GitHubActionsRedirectGuard()
        let guardedSession = URLSession(
            configuration: session.configuration,
            delegate: guardDelegate,
            delegateQueue: nil
        )
        defer { guardedSession.finishTasksAndInvalidate() }
        #if canImport(FoundationNetworking)
        // swift-corelibs transport has no incremental byte stream here; bound
        // the request and verify before returning.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await guardedSession.data(for: request)
        } catch {
            throw GitHubActionsError.transport(redact(error.localizedDescription, token: token))
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubActionsError.transport("GitHub did not return an HTTP response")
        }
        try checkDownloadResponse(http, token: token, maxBytes: maxBytes)
        guard data.count <= maxBytes else { throw GitHubActionsError.responseTooLarge(limit: maxBytes) }
        return data
        #else
        // Stream the body and stop reading as soon as the cap is crossed, so a
        // hostile or unexpectedly large artifact is never fully allocated. The
        // deferred invalidation cancels the still-open task when we throw.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await guardedSession.bytes(for: request)
        } catch {
            throw GitHubActionsError.transport(redact(error.localizedDescription, token: token))
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubActionsError.transport("GitHub did not return an HTTP response")
        }
        try checkDownloadResponse(http, token: token, maxBytes: maxBytes)
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(maxBytes) {
            throw GitHubActionsError.responseTooLarge(limit: maxBytes)
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        do {
            for try await byte in bytes {
                if data.count >= maxBytes {
                    throw GitHubActionsError.responseTooLarge(limit: maxBytes)
                }
                data.append(byte)
            }
        } catch let error as GitHubActionsError {
            throw error
        } catch {
            throw GitHubActionsError.transport(redact(error.localizedDescription, token: token))
        }
        return data
        #endif
    }

    private func checkDownloadResponse(_ http: HTTPURLResponse, token: String, maxBytes: Int) throws {
        guard (200..<300).contains(http.statusCode) else {
            let message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubActionsError.http(status: http.statusCode, message: redact(message, token: token))
        }
    }

    // MARK: Git-data snapshot publishing

    public func refSHA(owner: String, repository: String, branch: String, token: String) async throws -> String {
        let url = try apiURL(["repos", owner, repository, "git", "ref", "heads", branch])
        let ref: GitHubActionsGitRef = try await getJSON(url, token: token)
        return ref.objectSHA
    }

    public func commitTreeSHA(owner: String, repository: String, commitSHA: String, token: String) async throws -> String {
        let url = try apiURL(["repos", owner, repository, "git", "commits", commitSHA])
        let commit: GitHubActionsGitCommitObject = try await getJSON(url, token: token)
        return commit.treeSHA
    }

    public func createBlob(owner: String, repository: String, content: String, token: String) async throws -> String {
        let url = try apiURL(["repos", owner, repository, "git", "blobs"])
        let body = try JSONSerialization.data(withJSONObject: ["content": content, "encoding": "utf-8"])
        let (data, _) = try await send(url, method: "POST", token: token, body: body)
        return try Self.decoder.decode(GitHubActionsGitSHA.self, from: data).sha
    }

    public func createTree(
        owner: String, repository: String, baseTreeSHA: String?,
        entries: [GitHubActionsTreeEntry], token: String
    ) async throws -> String {
        let url = try apiURL(["repos", owner, repository, "git", "trees"])
        var payload: [String: Any] = [
            "tree": entries.map { ["path": $0.path, "mode": $0.mode, "type": $0.type, "sha": $0.sha] }
        ]
        if let baseTreeSHA { payload["base_tree"] = baseTreeSHA }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await send(url, method: "POST", token: token, body: body)
        return try Self.decoder.decode(GitHubActionsGitSHA.self, from: data).sha
    }

    public func createCommit(
        owner: String, repository: String, message: String, treeSHA: String,
        parentSHAs: [String], authorName: String, authorEmail: String,
        date: Date, token: String
    ) async throws -> String {
        let url = try apiURL(["repos", owner, repository, "git", "commits"])
        let stamp = Self.iso8601.string(from: date)
        let actor: [String: String] = ["name": authorName, "email": authorEmail, "date": stamp]
        let payload: [String: Any] = [
            "message": message,
            "tree": treeSHA,
            "parents": parentSHAs,
            "author": actor,
            "committer": actor
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await send(url, method: "POST", token: token, body: body)
        return try Self.decoder.decode(GitHubActionsGitSHA.self, from: data).sha
    }

    /// Creates the run-owned ref. A pre-existing ref is never force-moved:
    /// callers should use a fresh run token, and a conflict surfaces honestly.
    public func createRef(owner: String, repository: String, ref: String, sha: String, token: String) async throws {
        let url = try apiURL(["repos", owner, repository, "git", "refs"])
        let body = try JSONSerialization.data(withJSONObject: ["ref": ref, "sha": sha])
        _ = try await send(url, method: "POST", token: token, body: body)
    }

    public func deleteRef(owner: String, repository: String, ref: String, token: String) async throws {
        let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        let url = try apiURL(["repos", owner, repository, "git", "refs", "heads", branch])
        _ = try await send(url, method: "DELETE", token: token)
    }

    // MARK: Helpers

    private func redact(_ message: String, token: String) -> String {
        guard !token.isEmpty else { return message }
        return message.replacingOccurrences(of: token, with: "<redacted>")
    }

    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = iso8601Fractional.date(from: raw) { return date }
            if let date = iso8601.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid GitHub timestamp")
        }
        return decoder
    }()
}

/// Strips the API bearer token whenever a request is redirected to a different
/// host (artifact/log downloads land on pre-signed blob storage). Redirects to
/// a non-HTTPS destination are refused outright.
final class GitHubActionsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var forwarded = request
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        if forwarded.url?.host?.lowercased() != originalHost {
            forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(forwarded)
    }
}

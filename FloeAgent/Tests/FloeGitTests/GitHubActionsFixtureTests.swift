// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsFixtureTests — pure FloeGit-level tests for the GitHub Actions
// wire models and client. There is no live GitHub call: JSON fixtures prove the
// snake_case `CodingKeys`, association chooses/refuses correctly, pagination is
// host- and page-bounded, and the client builds dispatch/ref requests, maps a
// 404 to `nil`, caps artifact size before the network and strips the bearer
// token on a signed redirect. An in-process URLProtocol stands in for the
// transport.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeGit

// MARK: - URLProtocol fixture

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func prepare(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock(); Self.handler = handler; recorded = []; lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.recorded.append(captured)
        let handler = Self.handler
        Self.lock.unlock()
        let response = handler?(captured) ?? Response(status: 500, headers: [:], body: Data())
        guard let url = captured.url,
              let http = HTTPURLResponse(
                  url: url, statusCode: response.status,
                  httpVersion: "HTTP/1.1", headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // Custom protocols must forward redirects; otherwise the fixture would
        // return the 3xx as a final response and hide the production guard.
        if (300..<400).contains(response.status),
           let location = response.headers["Location"],
           let nextURL = URL(string: location, relativeTo: url) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: nextURL), redirectResponse: http)
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeClient() -> GitHubActionsClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    return GitHubActionsClient(session: URLSession(configuration: configuration))
}

private func json(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

@Suite("GitHubActionsFixtureTests", .serialized)
struct GitHubActionsFixtureTests {

    // MARK: - Wire model decoding (the snake_case CodingKeys contract)

    @Test func runDecodesGitHubSnakeCaseKeys() throws {
        let data = json([
            "id": 11, "workflow_id": 7, "run_number": 3, "event": "workflow_dispatch",
            "status": "completed", "conclusion": "success", "head_sha": "abc123",
            "head_branch": "floe-ide/x", "html_url": "https://github.com/o/r/actions/runs/11",
            "created_at": "2026-01-01T00:00:00Z",
            "run_started_at": "2026-01-01T00:00:02Z",
            "updated_at": "2026-01-01T00:01:00Z"
        ])
        let run = try GitHubActionsClient.decoder.decode(GitHubActionsRun.self, from: data)
        #expect(run.id == 11)
        #expect(run.workflowID == 7)
        #expect(run.runNumber == 3)
        #expect(run.headSHA == "abc123")
        #expect(run.headBranch == "floe-ide/x")
        #expect(run.htmlURL?.absoluteString == "https://github.com/o/r/actions/runs/11")
        #expect(run.isTerminal)
        #expect(run.succeeded)
    }

    @Test func jobAndArtifactDecodeSnakeCaseKeys() throws {
        let jobData = json([
            "id": 5, "name": "build", "status": "completed", "conclusion": "success",
            "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:02:00Z"
        ])
        let job = try GitHubActionsClient.decoder.decode(GitHubActionsJob.self, from: jobData)
        #expect(job.name == "build")
        #expect(job.conclusion == "success")
        #expect(job.completedAt != nil)

        let artifactData = json([
            "id": 9, "name": "floe-rust-build", "size_in_bytes": 1234, "expired": false,
            "archive_download_url": "https://api.github.com/repos/o/r/actions/artifacts/9/zip",
            "created_at": "2026-01-01T00:00:00Z", "expires_at": "2026-01-31T00:00:00Z"
        ])
        let artifact = try GitHubActionsClient.decoder.decode(GitHubActionsArtifact.self, from: artifactData)
        #expect(artifact.sizeInBytes == 1234)
        #expect(artifact.expired == false)
        #expect(artifact.expiresAt != nil)
    }

    @Test func runRejectsCamelCaseKeysInsteadOfSilentlyDecoding() {
        // Regression guard: a wire response using camelCase must not decode,
        // which is what makes the explicit CodingKeys contract observable.
        let data = json([
            "id": 11, "workflowID": 7, "runNumber": 3, "event": "workflow_dispatch",
            "status": "completed", "headSHA": "abc123", "created_at": "2026-01-01T00:00:00Z"
        ])
        #expect(throws: (any Error).self) {
            _ = try GitHubActionsClient.decoder.decode(GitHubActionsRun.self, from: data)
        }
    }

    // MARK: - Dispatch association

    private func receipt(baseline: Set<Int64>, returned: Int64?) -> GitHubActionsDispatchReceipt {
        GitHubActionsDispatchReceipt(
            owner: "octo", repository: "demo", workflowID: 7, ref: "floe-ide/x",
            headSHA: "snapshot", dispatchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baselineRunIDs: baseline, returnedRunID: returned
        )
    }

    private func run(_ id: Int64, sha: String, branch: String = "floe-ide/x") -> GitHubActionsRun {
        GitHubActionsRun(
            id: id, workflowID: 7, runNumber: Int(id), event: "workflow_dispatch",
            status: "queued", conclusion: nil, headSHA: sha, headBranch: branch,
            htmlURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            runStartedAt: nil, updatedAt: nil
        )
    }

    @Test func baselineRunsAreExcludedLeavingNotFound() {
        let result = GitHubActionsRunAssociation.select(
            candidates: [run(1, sha: "snapshot"), run(2, sha: "snapshot")],
            receipt: receipt(baseline: [1, 2], returned: nil)
        )
        #expect(result == .failure(.notFound))
    }

    @Test func uniqueSnapshotMatchIsAdopted() throws {
        let result = GitHubActionsRunAssociation.select(
            candidates: [run(3, sha: "snapshot")],
            receipt: receipt(baseline: [1, 2], returned: nil)
        )
        let match = try result.get()
        #expect(match.id == 3)
    }

    @Test func twoMatchesFailClosedAsAmbiguous() {
        let result = GitHubActionsRunAssociation.select(
            candidates: [run(3, sha: "snapshot"), run(4, sha: "snapshot")],
            receipt: receipt(baseline: [1, 2], returned: nil)
        )
        #expect(result == .failure(.ambiguous(runIDs: [3, 4])))
    }

    @Test func explicitReturnedRunIDIsAuthoritative() throws {
        let result = GitHubActionsRunAssociation.select(
            candidates: [run(8, sha: "snapshot"), run(9, sha: "snapshot")],
            receipt: receipt(baseline: [], returned: 9)
        )
        let match = try result.get()
        #expect(match.id == 9)
    }

    // MARK: - Pagination

    @Test func paginationParsesNextAndRefusesCrossHost() {
        let origin = URL(string: "https://api.github.com/")!
        let header = #"<https://api.github.com/x?page=2>; rel="next", <https://evil.example/x>; rel="prev""#
        let next = GitHubActionsPagination.nextURL(fromLinkHeader: header)
        #expect(next?.absoluteString == "https://api.github.com/x?page=2")
        #expect(GitHubActionsPagination.isFollowable(next: next!, origin: origin))
        #expect(!GitHubActionsPagination.isFollowable(
            next: URL(string: "https://evil.example/x")!, origin: origin
        ))
        #expect(GitHubActionsPagination.perPage(1000) == 100)
        #expect(GitHubActionsPagination.maximumPages == 5)
    }

    // MARK: - Client request/response behavior

    @Test func dispatch200ParsesRunIDAndPinsAPIVersion() async throws {
        FixtureURLProtocol.prepare { _ in
            FixtureURLProtocol.Response(
                status: 200, headers: ["Content-Type": "application/json"],
                body: json([
                    "workflow_run_id": 314159,
                    "run_url": "https://api.github.com/repos/octo/demo/actions/runs/314159",
                    "html_url": "https://github.com/octo/demo/actions/runs/314159"
                ])
            )
        }
        let result = try await makeClient().triggerDispatch(
            owner: "octo", repository: "demo", workflowID: 7, ref: "floe-ide/x",
            inputs: ["target_file": "src/main.rs"], token: "s3cret"
        )
        #expect(result.runID == 314159)
        #expect(result.htmlURL?.absoluteString == "https://github.com/octo/demo/actions/runs/314159")
        #expect(!result.acknowledgedWithoutBody)
        let request = try #require(FixtureURLProtocol.requests().last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    @Test func legacy204IsAnExplicitEmptyAcknowledgement() async throws {
        FixtureURLProtocol.prepare { _ in
            FixtureURLProtocol.Response(status: 204, headers: [:], body: Data())
        }
        let result = try await makeClient().triggerDispatch(
            owner: "octo", repository: "demo", workflowID: 7, ref: "main",
            inputs: [:], token: "s3cret"
        )
        #expect(result.runID == nil)
        #expect(result.acknowledgedWithoutBody)
    }

    @Test func fileContent404IsNilNotAnError() async throws {
        FixtureURLProtocol.prepare { _ in
            FixtureURLProtocol.Response(status: 404, headers: [:], body: json(["message": "Not Found"]))
        }
        let missing = try await makeClient().fileContent(
            owner: "octo", repository: "demo", path: ".github/workflows/floe.yml",
            ref: "main", token: "t"
        )
        #expect(missing == nil)
    }

    @Test func oversizedArtifactThrowsBeforeTouchingTheNetwork() async {
        FixtureURLProtocol.prepare { _ in
            Issue.record("oversized artifact must not reach the network")
            return FixtureURLProtocol.Response(status: 200, headers: [:], body: Data())
        }
        let artifact = GitHubActionsArtifact(
            id: 1, name: "big",
            sizeInBytes: Int64(GitHubActionsClient.maximumArtifactBytes) + 1,
            expired: false,
            archiveDownloadURL: URL(string: "https://api.github.com/repos/octo/demo/actions/artifacts/1/zip")!,
            createdAt: Date(), expiresAt: nil
        )
        do {
            _ = try await makeClient().downloadArtifact(artifact: artifact, token: "t")
            Issue.record("expected responseTooLarge")
        } catch GitHubActionsError.responseTooLarge {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func signedRedirectStripsTheBearerToken() async throws {
        FixtureURLProtocol.prepare { request in
            if request.url?.host?.contains("api.github.com") == true {
                return FixtureURLProtocol.Response(
                    status: 302,
                    headers: ["Location": "https://objects.example.com/signed/blob.zip"],
                    body: Data()
                )
            }
            return FixtureURLProtocol.Response(status: 200, headers: [:], body: Data([0x50, 0x4B]))
        }
        let artifact = GitHubActionsArtifact(
            id: 2, name: "small", sizeInBytes: 2, expired: false,
            archiveDownloadURL: URL(string: "https://api.github.com/repos/octo/demo/actions/artifacts/2/zip")!,
            createdAt: Date(), expiresAt: nil
        )
        let download = try await makeClient().downloadArtifact(artifact: artifact, token: "s3cret")
        #expect(download.data == Data([0x50, 0x4B]))
        #expect(download.sourceHost == "api.github.com")
        let requests = FixtureURLProtocol.requests()
        let first = requests.first { $0.url?.host?.contains("api.github.com") == true }
        let second = requests.first { $0.url?.host?.contains("objects.example.com") == true }
        #expect(first?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        #expect(second?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func updateRefIsNeverForcedAndCarriesTheCommit() async throws {
        FixtureURLProtocol.prepare { _ in
            FixtureURLProtocol.Response(status: 200, headers: [:], body: json(["object": ["sha": "x"]]))
        }
        try await makeClient().updateRef(
            owner: "octo", repository: "demo", branch: "main", sha: "abc", token: "t"
        )
        let request = try #require(FixtureURLProtocol.requests().last)
        #expect(request.httpMethod == "PATCH")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"force\":false") || body.contains("\"force\": false"))
        #expect(body.contains("\"sha\":\"abc\"") || body.contains("\"sha\": \"abc\""))
    }
}

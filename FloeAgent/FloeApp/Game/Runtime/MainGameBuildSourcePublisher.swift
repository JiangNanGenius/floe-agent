// SPDX-License-Identifier: MPL-2.0
#if canImport(FloeGit)
import Foundation
import FloeCore
import FloeGit
import FloeGameBuildKit
import FloeGameCore

/// `GameBuildSourcePublisherPort` over Main's GitHub Actions/Git-data client.
/// It publishes exactly the manifest passed by `GameBuildCoordinator`; it never
/// enumerates the working tree or substitutes a newer commit.
public struct MainGameBuildSourcePublisher: GameBuildSourcePublisherPort {
    private let client: GitHubActionsClient
    private let github: GitHubService
    private let credentials: GitHubCredentialStore
    /// Base branch from which each run ref is created. The `branch` argument to
    /// `publish` is the per-run target branch.
    private let baseBranch: String

    public init(client: GitHubActionsClient, github: GitHubService,
                credentials: GitHubCredentialStore, baseBranch: String) {
        self.client = client
        self.github = github
        self.credentials = credentials
        self.baseBranch = baseBranch
    }

    public func publish(_ snapshot: GameBuildSourceSnapshot,
                        owner: String, repository: String, branch: String) async throws
        -> GameBuildRepositorySnapshot {
        let token = try requireToken()
        // The coordinator passes its configured base branch here. A publisher
        // must never move that branch; create a unique run-owned ref instead.
        let targetBranch = branch == baseBranch
            ? "floe-game-source-" + UUID().uuidString.lowercased()
            : branch
        guard snapshot.files.count <= 20_000,
              snapshot.directories.count <= 20_000 else {
            throw GameBuildTransportError.invalidRepository("source snapshot is too large")
        }
        // The reviewed CI digest excludes generated `out` content. Refuse a
        // source snapshot that would produce a different digest there instead
        // of publishing bytes the workflow will silently omit.
        if snapshot.files.contains(where: {
            let value = $0.path.value
            return value == "out" || value.hasPrefix("out/")
                || value == ".floe" || value.hasPrefix(".floe/")
                || value == ".git" || value.hasPrefix(".git/")
        }) {
            throw GameBuildTransportError.invalidRepository(
                "The project contains generated '.floe', '.git' or 'out' content. CI excludes these from the source digest; remove or relocate them before publishing.")
        }
        let baseSHA = try await client.refSHA(
            owner: owner, repository: repository, branch: baseBranch, token: token)
        let rows = snapshot.files.map {
            "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable ? "1" : "0")"
        }.sorted()
        guard GameDigest.sha256(Data(rows.joined(separator: "\n").utf8)) == snapshot.digest else {
            throw GameBuildTransportError.staleDigest
        }
        var entries: [GitHubActionsTreeEntry] = []
        entries.reserveCapacity(snapshot.files.count)
        for file in snapshot.files {
            try Task.checkCancellation()
            let url = snapshot.rootURL.appendingPathComponent(file.path.value)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw GameBuildTransportError.invalidRepository(
                    "source entry is not a regular file: \(file.path.value)")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                throw GameBuildTransportError.invalidRepository(
                    "source changed during publish: \(file.path.value)")
            }
            let blob = try await client.createBlobBase64(
                owner: owner, repository: repository,
                content: data.base64EncodedString(), token: token)
            entries.append(.init(path: file.path.value, mode: file.executable ? "100755" : "100644",
                                 type: "blob", sha: blob))
        }
        // Build the run tree from exactly the published files. Using the base
        // branch tree would leave unrelated repository files in the checkout
        // and make the reviewed whole-project digest impossible to satisfy.
        let tree = try await client.createTree(
            owner: owner, repository: repository, baseTreeSHA: nil,
            entries: entries, token: token)
        let account = try await github.account(token: token)
        let authorName = account.name ?? account.login
        let commit = try await client.createCommit(
            owner: owner, repository: repository,
            message: "Floe game source \(snapshot.revision)",
            treeSHA: tree, parentSHAs: [baseSHA],
            authorName: authorName,
            authorEmail: "\(account.login)@users.noreply.github.com",
            date: Date(), token: token)
        try await client.createRef(
            owner: owner, repository: repository,
            ref: "refs/heads/\(targetBranch)", sha: commit, token: token)
        return try .init(owner: owner, repository: repository, branch: targetBranch,
                         commitSHA: commit, treeSHA: tree,
                         manifestDigest: snapshot.digest, revision: snapshot.revision,
                         gameRoot: snapshot.gameRoot,
                         selectedSourceDigest: snapshot.selectedSourceDigest)
    }

    public func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws
        -> GameBuildArtifactIdentity {
        let token = try requireToken()
        let artifacts = try await client.artifacts(
            owner: reference.owner, repository: reference.repository,
            runID: reference.runID, token: token, maxPages: 3)
        guard let artifact = artifacts.first(where: {
            $0.id == reference.artifactID && $0.name == reference.name
        }) else {
            throw GameBuildTransportError.artifactMissing
        }
        guard !artifact.expired, artifact.sizeInBytes > 0,
              artifact.sizeInBytes <= Int64(GameBuildCILimits.maximumArtifactBytes) else {
            throw GameBuildTransportError.artifactExpired
        }
        let wrapper = try await client.downloadArtifact(
            artifact: artifact, token: token,
            maxBytes: GameBuildCILimits.maximumArtifactBytes).data
        let payload = try unwrap(wrapper, expectedName: reference.name)
        guard payload.count == reference.bytes,
              GameDigest.sha256(payload) == reference.sha256 else {
            throw GameBuildTransportError.artifactMismatch
        }
        return .init(name: reference.name, sha256: reference.sha256, bytes: reference.bytes,
                     runID: reference.runID, artifactID: reference.artifactID,
                     sourceDigest: reference.sourceDigest,
                     revision: reference.revision ?? "", engine: "",
                     templateID: "source-transport", expired: false,
                     gameRoot: reference.gameRoot,
                     selectedSourceDigest: reference.selectedSourceDigest)
    }

    private func requireToken() throws -> String {
        guard let token = try credentials.token(), !token.isEmpty else {
            throw GameBuildTransportError.invalidRepository(
                "Connect GitHub in the existing credential settings before publishing source.")
        }
        return token
    }

    /// GitHub returns a zip wrapper containing the uploaded file. A raw zip is
    /// accepted only when it is already the referenced payload.
    private func unwrap(_ data: Data, expectedName: String) throws -> Data {
        guard data.starts(with: [0x50, 0x4b]) else { return data }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-source-verify-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let archive = temporary.appendingPathComponent("wrapper.zip")
        try data.write(to: archive, options: .withoutOverwriting)
        let unpacked = temporary.appendingPathComponent("unpacked", isDirectory: true)
        do {
            _ = try GameArchiveExchange().extract(archive: archive, to: unpacked)
        } catch {
            return data
        }
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: unpacked.path)) ?? []
        if let match = files.first(where: {
            $0 == expectedName || $0.hasSuffix("/" + expectedName)
        }) {
            return try Data(contentsOf: unpacked.appendingPathComponent(match))
        }
        if expectedName == "floe-game-source" {
            let zips = files.filter { $0.lowercased().hasSuffix(".zip") }
            if zips.count == 1 {
                return try Data(contentsOf: unpacked.appendingPathComponent(zips[0]))
            }
        }
        return data
    }
}
#endif

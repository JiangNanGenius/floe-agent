// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGit

/// A user-selected existing GitHub repository context. It stores routing
/// metadata only: no token, account secret, signing identity or developer-paid
/// plan. The actual `GitHubCredentialStore` remains the credential authority.
struct GameBuildRepositorySelection: Codable, Equatable, Sendable {
    let owner: String
    let repository: String
    let branch: String
    let fullName: String

    init(owner: String, repository: String, branch: String) throws {
        let clean = { (value: String) -> String in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let owner = clean(owner), repository = clean(repository), branch = clean(branch)
        guard !owner.isEmpty, !repository.isEmpty, !branch.isEmpty,
              owner.utf8.count <= 128, repository.utf8.count <= 128, branch.utf8.count <= 256,
              !owner.contains("/"), !repository.contains("/"), !branch.contains(" "),
              [owner, repository, branch].allSatisfy({ value in
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else {
            throw GameBuildRepositorySettingsError.invalidSelection
        }
        self.owner = owner
        self.repository = repository
        self.branch = branch
        self.fullName = owner + "/" + repository
    }

    init(repository: GitHubRepository, branch: String? = nil) throws {
        let parts = repository.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GameBuildRepositorySettingsError.invalidSelection }
        try self.init(owner: parts[0], repository: parts[1],
                      branch: branch ?? repository.defaultBranch)
    }
}

enum GameBuildRepositorySettingsError: Error, Equatable, LocalizedError {
    case invalidSelection
    case credentialStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Choose an existing GitHub repository and branch."
        case .credentialStoreUnavailable:
            return "The selected GitHub credential context is unavailable. Sign in to the existing GitHub account first."
        }
    }
}

/// Durable but non-secret routing preference. It is not authorization: the
/// build service still validates the existing credential, repository and
/// branch through the real GitHub clients.
enum GameBuildRepositorySettings {
    private static let key = "floe.game.build.repository.v1"
    private static let sourceUploadConsentKey = "floe.game.build.sourceUploadConsent.v1"
    private static let maximumBytes = 4_096

    static func load() -> GameBuildRepositorySelection? {
        guard let data = UserDefaults.standard.data(forKey: key), data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(GameBuildRepositorySelection.self, from: data)
    }

    static func save(_ selection: GameBuildRepositorySelection) throws {
        let data = try JSONEncoder().encode(selection)
        guard data.count <= maximumBytes else { throw GameBuildRepositorySettingsError.invalidSelection }
        // A new repository/branch choice requires a fresh source-upload
        // consent; never inherit consent from another destination.
        UserDefaults.standard.removeObject(forKey: sourceUploadConsentKey)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: sourceUploadConsentKey)
    }

    /// Explicit user permission to upload the project's saved source snapshot
    /// to the selected CI repository. It is routing metadata, not a credential
    /// and not a model-granted permission.
    static func sourceUploadConsent() -> Bool {
        UserDefaults.standard.bool(forKey: sourceUploadConsentKey)
    }

    static func setSourceUploadConsent(_ value: Bool) {
        if value { UserDefaults.standard.set(true, forKey: sourceUploadConsentKey) }
        else { UserDefaults.standard.removeObject(forKey: sourceUploadConsentKey) }
    }

    static func configuration() -> GameGitHubExecutionConfiguration? {
        guard let selection = load() else { return nil }
        return try? GameGitHubExecutionConfiguration(owner: selection.owner,
            repository: selection.repository, baseBranch: selection.branch)
    }

    /// A route is usable only when the existing Keychain credential can be
    /// read. The raw token is never returned, logged or persisted here.
    static func validated(_ configuration: GameGitHubExecutionConfiguration)
        -> GameGitHubExecutionConfiguration? {
        guard let token = try? configuration.credentials.token(),
              !token.isEmpty else { return nil }
        return configuration
    }

    static func validatedConfiguration() -> GameGitHubExecutionConfiguration? {
        configuration().flatMap(validated)
    }
}
#endif

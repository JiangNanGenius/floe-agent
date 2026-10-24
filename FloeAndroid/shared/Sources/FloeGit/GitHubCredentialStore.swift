// SPDX-License-Identifier: MPL-2.0
//
// GitHubCredentialStore — Android platform adapter for the iOS Keychain-backed
// credential store (FloeAgent/Sources/FloeGit/GitHubCredentialStore.swift at
// public 3fd597b5). This file is a NARROW DOCUMENTED PLATFORM MIRROR, not a
// byte-exact copy:
//
//   * The original backend is FloeSecurity.KeychainStore, which is EXCLUDED
//     from the Android shared graph entirely (shared/Package.swift header: the
//     non-Security branch is a process-wide RAM store, forbidden on Android —
//     fail-closed directive). There is deliberately NO Keychain and NO RAM
//     fallback here.
//   * On Android the ONE token authority is the existing Kotlin Keystore vault
//     (core/credentials GitHubCredentialStore.kt: SERVICE
//     "org.floeagent.ios.github" / ACCOUNT "github.primary", opaque
//     `keychainAccount` reference, same 20…512 printable-ASCII validation),
//     reached through the Core-owned secure gateway. FloeGit therefore accepts
//     a LEASED CREDENTIAL SEAM: the lease implementation lives behind Core's
//     gateway ingress (the SecretGatewayRegistry pattern already qualified in
//     G02). This module never persists, caches, logs or re-validates token
//     bytes into durable state, and it never implements a second store.
//   * API deltas against the original (everything else keeps the same shape
//     and typing):
//       - `token()` becomes `async` because the only Android read path is the
//         typed async secret gateway; callers inside the async tool runners
//         await it directly. No sync-blocking wrapper is introduced.
//       - `save(token:)`/`delete()` are NOT mirrored here: the shipped Android
//         token editor already writes through the Kotlin vault (host
//         GitHubCredentialHostController). Adding Swift writes would create a
//         second ingress over one store for no consumer.
//       - An UNCONFIGURED seam (no Core lease installed) reads as "no account
//         connected" — exactly the original item-not-found typing (`token()`
//         returns nil; auth-requiring tools then throw
//         FloeError.invalidConfiguration). Fail-closed, never a fabricated
//         credential.
//   * `service`/`account` keep the original constant values because the
//     Android vault was deliberately pinned to the same identity
//     (GitHubCredentialStore.kt SERVICE/ACCOUNT), so the gateway reference the
//     Core lease computes addresses the SAME record as iOS did.
import Foundation

/// The one value FloeGit ever receives from the platform vault: the connected
/// GitHub token, or `nil` when no account is connected. Implementations run
/// behind the Core-owned secure gateway; the returned string must be used for
/// one request set and then dropped — never stored on a model, logged, placed
/// in a URL, or handed to a subprocess environment.
public protocol GitHubCredentialLeasing: Sendable {
    func leasedToken() async throws -> String?
}

/// Fail-closed default: no lease installed means no token. The type itself
/// holds no storage of any kind.
public struct UnconfiguredGitHubCredentialLease: GitHubCredentialLeasing {
    public init() {}
    public func leasedToken() async throws -> String? { nil }
}

public struct GitHubCredentialStore: Sendable {
    /// Stable vault identity shared with the original iOS Keychain service and
    /// the Android Kotlin vault constant. Public identity, not a credential.
    public static let service = "org.floeagent.ios.github"
    public static let account = "github.primary"

    private let lease: any GitHubCredentialLeasing

    /// Default construction stays source-compatible with the original
    /// (`registerGitTools(rootProvider:)` default argument) and means
    /// "no vault bound yet" → every read is a typed nil.
    public init() {
        lease = UnconfiguredGitHubCredentialLease()
    }

    /// The production seam: the Main-owned runtime composition constructs the
    /// store with the real gateway-backed lease once at startup. Nothing in
    /// this module can observe or replace that lease afterwards.
    public init(lease: any GitHubCredentialLeasing) {
        self.lease = lease
    }

    /// The only credential read FloeGit performs. Errors from the vault
    /// (corruption, gateway failure, cancellation) propagate typed; they are
    /// never swallowed into "no account".
    public func token() async throws -> String? {
        try await lease.leasedToken()
    }
}

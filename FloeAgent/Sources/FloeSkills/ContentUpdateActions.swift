import Foundation

/// Read-only availability for the exact stored packages, never a synthetic
/// "previous" version inferred from an app baseline or a version label.
public struct ContentUpdateActionSnapshot: Sendable {
    public let state: ContentUpdateState
    public let rollbackTargets: [String: ContentUpdateState.StoredEntry]
}

public enum ContentUpdateActionPolicy {
    /// A real rollback leaves the newer package in retained history. Respect
    /// that decision during automatic checks until a release beyond it is
    /// available. Explicit installation uses the ordinary verified store path.
    public static func automaticUpdateAllowed(id: String, version: String, state: ContentUpdateState) -> Bool {
        guard let proposed = try? SignedContentVersion(version) else { return false }
        guard let active = state.entries[id], let current = try? SignedContentVersion(active.entry.version) else { return true }
        let restoredFrom = (state.history[id] ?? []).compactMap { prior -> SignedContentVersion? in
            guard prior.entry.id == id, let retained = try? SignedContentVersion(prior.entry.version), retained > current else { return nil }
            return retained
        }.max()
        guard let restoredFrom else { return true }
        return proposed > restoredFrom
    }
}

extension ContentUpdateStore {
    /// Uses the same bounded path/file reader and digest contract as rollback.
    /// A package below the bundle's effective baseline cannot remain active
    /// after app takeover, so it is not an actionable restore target here.
    public func actionSnapshot(
        appVersion: String,
        builtInBaselines: [String: String] = [:],
        domainValidate: @Sendable (SignedContentEntry, [String: Data]) throws -> Void
    ) -> ContentUpdateActionSnapshot {
        let snapshot = currentState()
        var targets: [String: ContentUpdateState.StoredEntry] = [:]
        for (id, active) in snapshot.entries {
            for prior in snapshot.history[id] ?? [] {
                let entry = prior.entry
                guard entry.id == id, entry.kind == active.entry.kind,
                      let retainedVersion = try? SignedContentVersion(entry.version),
                      let activeVersion = try? SignedContentVersion(active.entry.version),
                      retainedVersion < activeVersion,
                      entry.isCompatible(appVersion: appVersion),
                      entry.dependencies.allSatisfy({ snapshot.entries[$0] != nil }) else { continue }
                if let baseline = builtInBaselines[id] {
                    guard let bundled = try? SignedContentVersion(baseline),
                          let retained = try? SignedContentVersion(entry.version),
                          retained >= bundled else { continue }
                }
                if let digest = snapshot.ledger[id]?[entry.version], digest != entry.contentDigest.lowercased() { continue }
                do {
                    let retainedFiles = try files(directory: prior.directory)
                    guard SignedContentArchive.canonicalDigest(retainedFiles) == entry.contentDigest.lowercased() else { continue }
                    try domainValidate(entry, retainedFiles)
                    targets[id] = prior
                    break
                } catch {
                    // Missing, incompatible or damaged history is retained
                    // for recovery, but is never advertised as a usable action.
                }
            }
        }
        return .init(state: snapshot, rollbackTargets: targets)
    }

    /// Re-check the derived rollback ceiling on this actor immediately before
    /// the existing transaction. A rollback completed during a download must
    /// not be undone by the older automatic batch, including dependencies.
    @discardableResult
    public func commitAutomatically(
        _ batch: [BatchItem],
        appVersion: String,
        allowedCapabilities: Set<String>,
        domainValidate: @escaping @Sendable (SignedContentEntry, [String: Data]) throws -> Void
    ) throws -> ContentUpdateState {
        let snapshot = currentState()
        for item in batch {
            guard ContentUpdateActionPolicy.automaticUpdateAllowed(id: item.entry.id,
                version: item.entry.version, state: snapshot) else {
                throw ContentUpdateStoreError.conflict("automatic update would undo rollback for \(item.entry.id)")
            }
        }
        return try commit(batch, appVersion: appVersion,
            allowedCapabilities: allowedCapabilities, domainValidate: domainValidate)
    }

    /// The pin action was removed. Retire only that obsolete policy state;
    /// immutable package/history/run records remain untouched. Repeated calls
    /// are no-ops after migration, and failed writes remain retryable.
    @discardableResult
    public func removeVersionPins() throws -> ContentUpdateState {
        for id in currentState().pinned.keys.sorted() {
            try setPinned(id: id, version: nil)
        }
        return currentState()
    }
}

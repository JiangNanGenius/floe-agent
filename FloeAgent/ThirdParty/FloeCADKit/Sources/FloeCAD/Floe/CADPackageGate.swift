//
//  CADPackageGate.swift
//  FloeCADKit
//
//  In-process atomic gate for one `.floecad` package path.
//
//  Every SUPPORTED writer commits through `FileCADDocumentStore`, which
//  acquires this gate for the duration of a package commit. The Canvas
//  cancellation route holds the SAME gate from its final exact-identity
//  re-check through node/package removal, so a foreign in-app session (another
//  store instance, a CAD service, a second workbench) can never land a commit
//  in the verify→delete window:
//
//    * a write that lands BEFORE the final re-check moves the revision/content
//      identity and the cancellation refuses, preserving it;
//    * a write that starts while the cancellation holds the gate is serialized
//      AFTER it — the package manifest is then gone, so the store's disk CAS
//      refuses the commit instead of resurrecting or overwriting anything.
//
//  This is deliberately an IN-PROCESS gate for cooperating writers. Arbitrary
//  non-cooperating writers (another process editing the files directly) are
//  not serialized by it; the cancellation additionally re-reads the exact
//  committed identity immediately before removal, but no cross-process
//  filesystem lock is claimed.
//

import Foundation

nonisolated public enum CADPackageGate {
    /// Lock-protected registry of one binary semaphore per canonical package
    /// path. The semaphores are never removed: package paths are bounded by
    /// the app's canvases and the memory cost is negligible.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [String: DispatchSemaphore] = [:]

        func semaphore(for key: String) -> DispatchSemaphore {
            lock.lock()
            defer { lock.unlock() }
            if let existing = gates[key] { return existing }
            let semaphore = DispatchSemaphore(value: 1)
            gates[key] = semaphore
            return semaphore
        }
    }

    private static let registry = Registry()

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func semaphore(for url: URL) -> DispatchSemaphore {
        registry.semaphore(for: key(for: url))
    }

    /// Blocking acquire for store writers. Store commits already run off the
    /// main actor, so blocking the calling thread is expected.
    public static func acquire(_ url: URL) {
        semaphore(for: url).wait()
    }

    /// Release a previously acquired gate.
    public static func release(_ url: URL) {
        semaphore(for: url).signal()
    }

    /// Async acquire for the cancellation path: the wait happens on a
    /// background thread, so the caller's actor stays free.
    public static func acquireAsync(_ url: URL) async {
        let semaphore = semaphore(for: url)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}

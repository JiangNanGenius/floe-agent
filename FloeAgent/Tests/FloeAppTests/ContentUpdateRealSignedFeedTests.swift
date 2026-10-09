// FloeAppTests — Real signed content feed check → install → effective chain.
//
// SPDX-License-Identifier: MPL-2.0
//
// Targeted integration verification for the App-side signed-content path that
// was previously implemented but never exercised end-to-end. It drives the
// REAL `ContentUpdateCenter` + REAL `ContentUpdateStore` (real feed
// verification against the compiled Ed25519 trust root, real version policy,
// real atomic store commit, real review cache AND real run-time overlay
// consumption) against the IMMUTABLE, already-published commit 8121c9d4… using
// genuine published bytes fetched over the network.
//
// The network transport is a test-side reproduction of the anonymous public
// GitHub REST call that `SourceControlCenter.skillRepositoryData` performs
// (same endpoint, Accept headers, no-redirect policy and size bound); it is a
// transport harness, not a content mock — every returned byte is the real
// signed hub object. What is under test is the Center + Store chain against
// those real bytes. The production default (`main`) source is untouched,
// nothing is published, and no parallel updater is introduced: the only
// injected seams are the bytes' ref (a frozen SHA) and an isolated store root.
//
// Network is genuinely required: a transport failure FAILS the test instead of
// passing on a mock or skip, so a green run proves the real signed chain.

#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import Testing
@testable import FloeApp
import FloeCore
import FloeSkills

private struct RealFeedFailure: Error, CustomStringConvertible {
    let detail: String
    var description: String { "real signed feed chain could not run: \(detail)" }
}

@Suite("FloeApp.ContentUpdateRealSignedFeed")
@MainActor
struct ContentUpdateRealSignedFeedTests {

    /// Immutable published commit "Publish signed official skill and content
    /// packages". Pinned here so the run is auditable and never follows a
    /// moving branch.
    private static let immutableCommit = "8121c9d4d435178d46f07f0088aec7196977210f"
    private static let promptsID = "floe.prompts.core"
    private static let publishedPromptsVersion = "1.2.0"

    // MARK: Real anonymous GitHub transport (mirrors SourceControlCenter)

    /// Byte-faithful reproduction of `SourceControlCenter.skillRepositoryData`
    /// for the anonymous content-hub path: same endpoint shapes, the same
    /// raw/commit Accept headers, the same no-redirect policy and the same
    /// 2 MiB bound (the real packages are a few KiB). It cannot carry
    /// credentials and it never follows a redirect to a different host.
    private static func makeRealTransport() -> ContentUpdateCenter.RepositoryFetch {
        { owner, repository, ref, path in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
            func encoded(_ value: String) -> String {
                value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            }
            var components = URLComponents(string: "https://api.github.com")!
            if let path {
                components.percentEncodedPath =
                    "/repos/\(encoded(owner))/\(encoded(repository))/contents/"
                    + path.split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
                components.queryItems = [URLQueryItem(name: "ref", value: ref)]
            } else {
                components.percentEncodedPath =
                    "/repos/\(encoded(owner))/\(encoded(repository))/commits/\(encoded(ref))"
            }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30
            request.setValue(path == nil ? "application/vnd.github+json"
                                         : "application/vnd.github.raw+json",
                             forHTTPHeaderField: "Accept")
            request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")

            final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
                func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
                    completionHandler(nil)
                }
            }
            let session = URLSession(configuration: .ephemeral,
                                     delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw FloeError.syncUnavailable(
                    "GitHub content source unavailable for \(path ?? "commit") @ \(ref)")
            }
            var result = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard result.count < 2_097_152 else {
                    throw FloeError.validationFailed("GitHub content download exceeds its size limit")
                }
                result.append(byte)
            }
            return result
        }
    }

    // MARK: UserDefaults isolation

    /// The production center binds its policy toggles to `UserDefaults.standard`
    /// and writes `lastCheck` on a successful check. Snapshot every key this
    /// test can touch, pin an explicit policy BEFORE the center's initializer
    /// reads it, and restore the prior values afterwards so neither other tests
    /// nor the simulator user state is polluted.
    private static let isolatedDefaultKeys = [
        "floe.content.update.automaticChecks",
        "floe.content.update.autoDeclarative",
        "floe.content.update.lastCheck"
    ]

    @discardableResult
    private func pinIsolatedDefaults() -> [String: Any?] {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any?] = [:]
        for key in Self.isolatedDefaultKeys { snapshot[key] = defaults.object(forKey: key) }
        defaults.set(true, forKey: "floe.content.update.automaticChecks")
        defaults.set(false, forKey: "floe.content.update.autoDeclarative")
        defaults.removeObject(forKey: "floe.content.update.lastCheck")
        return snapshot
    }

    private func restoreDefaults(_ snapshot: [String: Any?]) {
        let defaults = UserDefaults.standard
        for (key, value) in snapshot {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-realfeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCenter(root: URL) -> ContentUpdateCenter {
        ContentUpdateCenter.forImmutableCommit(
            Self.immutableCommit, root: root, fetch: Self.makeRealTransport())
    }

    private func waitFor(_ condition: @MainActor () -> Bool,
                         timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// A phrase present only in the SIGNED 1.2.0 delivery body, never in the
    /// compiled built-in `deliveringWork` text. Its presence proves the run
    /// consumed the installed signed package rather than the built-in freeze.
    private static let signedDeliveryMarker = "unrun checks"

    @Test("Real signed feed: check → verify → install prompts → review cache and run-time overlay consume signed bytes")
    func checkInstallEffective() async throws {
        let savedDefaults = pinIsolatedDefaults()
        defer { restoreDefaults(savedDefaults) }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root)
        center.load()

        // Before any signed package is installed the effective source is the
        // compiled built-in prompts (1.0.0), with no published sections. A run
        // started now consumes the frozen built-in delivery (no signed marker).
        await waitUntilSettled(center)
        #expect(center.effectivePromptsVersion() == ContentUpdateCenter.builtInPromptsVersion)
        #expect(center.promptSections().isEmpty)
        let beforeRun = UUID()
        let beforeOverlay = await center.runtimePromptOverlay(runID: beforeRun, locale: "en")
        #expect(beforeOverlay.delivery?.contains(Self.signedDeliveryMarker) != true)

        // CHECK: fetch commit metadata + index + signature over the real
        // network transport and verify with the compiled trust root.
        await center.checkForUpdates(force: true)
        if let failure = center.errorMessage {
            // Network is genuinely required for this integration check. A
            // transport failure must FAIL the test, never pass vacuously (a
            // mock/skip result would not prove the real signed chain).
            Issue.record("Real signed feed check failed (network/transport): \(failure)")
            throw RealFeedFailure(detail: "check: \(failure)")
        }
        guard let available = center.available[Self.promptsID] else {
            throw RealFeedFailure(detail: "feed carried no \(Self.promptsID) entry after check")
        }
        #expect(available.decision.isUpdate, "published 1.2.0 should be an update over built-in 1.0.0: \(available.decision)")
        #expect(available.entry.version == Self.publishedPromptsVersion)
        #expect(center.providerCatalogCommit == Self.immutableCommit)

        // INSTALL: download the signed package and commit through the real
        // atomic store transaction (hash/digest/domain re-validated there).
        await center.install(Self.promptsID)
        #expect(center.errorMessage == nil, "install reported: \(center.errorMessage ?? "")")
        let installed = center.installed[Self.promptsID]
        guard let installed else {
            throw RealFeedFailure(detail: "prompts package did not install")
        }
        #expect(installed.version == Self.publishedPromptsVersion)
        #expect(!installed.digest.isEmpty)

        // EFFECTIVE (review surface): the active cache now comes from the
        // signed package. This proves the review UI data, not model use.
        #expect(center.effectivePromptsVersion() == Self.publishedPromptsVersion)
        let sections = center.promptSections()
        #expect(!sections.isEmpty, "installed signed prompts must populate the review sections cache")
        let ids = Set(sections.map(\.id))
        #expect(ids.contains("floe.prompts.core.delivery"))
        let delivery = sections.first { $0.id == "floe.prompts.core.delivery" }
        #expect(delivery?.title["en"]?.isEmpty == false)
        print("FLOE_REAL_FEED_OK commit=\(Self.immutableCommit) installedVersion=\(installed.version) digest=\(installed.digest.prefix(16)) sections=\(sections.count)")

        // EFFECTIVE (run-time consumption): a run started after install must
        // resolve the ACTIVE signed directory through the same snapshot/overlay
        // path the agent uses, and its delivery body must be the signed bytes
        // (the marker is absent from the compiled built-in text). This — not
        // the review cache — is what proves the model actually consumes them.
        let runID = UUID()
        let overlay = await center.runtimePromptOverlay(runID: runID, locale: "en")
        #expect(overlay.delivery?.isEmpty == false, "run-time overlay must carry the signed delivery section")
        #expect(overlay.delivery?.contains(Self.signedDeliveryMarker) == true,
                "run-time overlay did not consume the signed delivery body")
        #expect(overlay.communication?.isEmpty == false)
        // The signed package also publishes a method section (built-in has
        // none compiled); resolving it proves all three replaceable slots.
        #expect(overlay.method?.isEmpty == false)
        // Chinese locale selects the signed zh-Hans body, not the English one.
        let zhOverlay = await center.runtimePromptOverlay(runID: UUID(), locale: "zh-Hans")
        #expect(zhOverlay.delivery?.isEmpty == false)
        #expect(zhOverlay.delivery != overlay.delivery, "zh-Hans run-time overlay must select localized bytes")

        // A second check against the same immutable feed now reports the
        // installed version up to date (immutability, no re-install churn).
        await center.checkForUpdates(force: true)
        #expect(center.errorMessage == nil, "recheck reported: \(center.errorMessage ?? "")")
        if let again = center.available[Self.promptsID], case .upToDate = again.decision {
            // expected
        } else if let again = center.available[Self.promptsID] {
            Issue.record("expected upToDate after install, got \(again.decision)")
        }
        // Rollback-to-retained-version and the atomic failure paths are owned
        // by ContentUpdateStoreTests; this immutable feed publishes only one
        // prompts version, so it has no second retained version to restore.
    }

    @Test("Real signed feed: a tampered signature is rejected by the compiled trust root")
    func tamperedSignatureRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetch = Self.makeRealTransport()
        let index = try await fetch(OfficialContentHub.owner, OfficialContentHub.repository,
                                    Self.immutableCommit, OfficialContentHub.indexPath)
        let signature = try await fetch(OfficialContentHub.owner, OfficialContentHub.repository,
                                        Self.immutableCommit, OfficialContentHub.signaturePath)
        // Corrupt the base64 Ed25519 proof inside the envelope (leave the JSON
        // envelope itself intact so rejection is a signature failure, not a
        // decode failure).
        struct Envelope: Codable { let keyID: String; var signature: String }
        var envelope = try JSONDecoder().decode(Envelope.self, from: signature)
        guard envelope.signature.count > 2 else {
            Issue.record("signature proof unexpectedly short")
            return
        }
        let chars = Array(envelope.signature)
        let last = chars.last!
        envelope.signature = String(chars.dropLast()) + (last == "A" ? "B" : "A")
        let tampered = try JSONEncoder().encode(envelope)

        let store = try ContentUpdateStore(root: root.appendingPathComponent("tamper", isDirectory: true))
        await #expect(throws: (any Error).self) {
            _ = try await store.verifyFeed(index: index, signature: tampered,
                                           trustedKeys: OfficialSkillHub.trustedKeys)
        }
    }

    private func waitUntilSettled(_ center: ContentUpdateCenter) async {
        _ = await waitFor { center.storageAvailable }
    }
}
#endif

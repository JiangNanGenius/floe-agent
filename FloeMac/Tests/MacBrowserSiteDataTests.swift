// SPDX-License-Identifier: MPL-2.0

import XCTest

// Focused tests for Mac task-browser site memory. WebKit data-store wiping
// runs against this app's own dedicated identifiers only; no network, no
// shared store, no Safari data.
//
// These tests compile into the same module as the unified sources (the
// FloeMacBridgeServiceTests pattern); no app-module import is used.

final class MacBrowserSiteDataTests: XCTestCase {
    private var fixtureDirectories: [URL] = []

    override func tearDown() {
        for url in fixtureDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        fixtureDirectories.removeAll()
        super.tearDown()
    }

    private func makeRegistryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-site-data-tests-\(UUID().uuidString)", isDirectory: true)
        fixtureDirectories.append(url)
        return url
    }

    // MARK: - Origin canonicalization

    @MainActor
    func testCanonicalOriginNormalizesSchemeHostAndDefaultPort() {
        XCTAssertEqual(
            MacSiteMemoryRegistry.canonicalOrigin(URL(string: "https://Example.com:443/path?x=1")!),
            "https://example.com"
        )
        XCTAssertEqual(
            MacSiteMemoryRegistry.canonicalOrigin(URL(string: "http://example.com:8080/a")!),
            "http://example.com:8080"
        )
        XCTAssertEqual(
            MacSiteMemoryRegistry.canonicalOrigin(URL(string: "http://example.com:80")!),
            "http://example.com"
        )
    }

    @MainActor
    func testCanonicalOriginRejectsNonHttpAndCredentials() {
        XCTAssertNil(MacSiteMemoryRegistry.canonicalOrigin(URL(string: "ftp://example.com")!))
        XCTAssertNil(MacSiteMemoryRegistry.canonicalOrigin(URL(string: "https://user:pass@example.com")!))
        XCTAssertNil(MacSiteMemoryRegistry.canonicalOrigin(URL(string: "file:///etc/passwd")!))
        XCTAssertNil(MacSiteMemoryRegistry.canonicalOrigin(URL(string: "javascript:alert(1)")!))
    }

    // MARK: - Remember / persist / reload

    @MainActor
    func testRememberedSiteSurvivesRegistryReload() {
        let directory = makeRegistryDirectory()
        let first = MacSiteMemoryRegistry(directory: directory)
        XCTAssertTrue(first.isPersistent)
        XCTAssertEqual(first.remember(url: URL(string: "https://app.example.com/login")!), "https://app.example.com")
        first.flush()

        let second = MacSiteMemoryRegistry(directory: directory)
        XCTAssertEqual(second.sites.map(\.origin), ["https://app.example.com"])
        // The store identifier is what makes the jar survive a relaunch; it
        // must be reused, not regenerated.
        XCTAssertEqual(second.store(for: URL(string: "https://app.example.com/")!),
                       second.store(for: URL(string: "https://app.example.com/dashboard")!))
    }

    @MainActor
    func testRememberRejectsDisallowedDuplicateAndExcess() {
        let directory = makeRegistryDirectory()
        let registry = MacSiteMemoryRegistry(directory: directory)
        XCTAssertNil(registry.remember(url: URL(string: "data:text/plain,hi")!))
        _ = registry.remember(url: URL(string: "https://one.example.com")!)
        XCTAssertNil(registry.remember(url: URL(string: "https://one.example.com/other")!),
                     "the same origin must not be stored twice")
        XCTAssertEqual(registry.sites.count, 1)
    }

    @MainActor
    func testMemoryOnlyRegistryCannotRemember() {
        let registry = MacSiteMemoryRegistry(directory: nil)
        XCTAssertFalse(registry.isPersistent)
        XCTAssertNil(registry.remember(url: URL(string: "https://app.example.com")!))
        XCTAssertTrue(registry.sites.isEmpty)
    }

    @MainActor
    func testCorruptArchiveMakesRegistryUnavailableWithoutReplacingIt() {
        let directory = makeRegistryDirectory()
        let registry = MacSiteMemoryRegistry(directory: directory)
        _ = registry.remember(url: URL(string: "https://app.example.com")!)
        registry.flush()
        let archive = directory.appendingPathComponent("remembered-sites.json")
        try! Data([0x00, 0x01, 0x02]).write(to: archive)

        let reloaded = MacSiteMemoryRegistry(directory: directory)
        XCTAssertFalse(reloaded.isAvailable)
        XCTAssertFalse(reloaded.isPersistent)
        XCTAssertTrue(reloaded.sites.isEmpty, "a corrupt archive must not be silently served as an empty registry")
        XCTAssertNil(reloaded.remember(url: URL(string: "https://new.example.com")!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "the corrupt archive stays in place for recovery")
    }

    // MARK: - Forgetting detaches before wiping

    @MainActor
    func testForgetDetachesJarsBeforeWiping() {
        let directory = makeRegistryDirectory()
        let registry = MacSiteMemoryRegistry(directory: directory)
        let origin = registry.remember(url: URL(string: "https://app.example.com")!)!
        let site = registry.sites.first!
        var invalidated: Set<UUID> = []
        var detachCallCount = 0
        var gatedDuringHook = false
        registry.onJarsInvalidated = { [weak registry] ids in
            detachCallCount += 1
            invalidated = ids
            // Resolution must already be gated while the wipe is announced:
            // a tab must never re-acquire the jar being removed.
            if let registry {
                gatedDuringHook = registry.store(for: URL(string: "https://app.example.com")!) == nil
            }
        }

        let expectation = self.expectation(description: "forget")
        Task {
            await registry.forget(origin: origin)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        XCTAssertEqual(invalidated, [site.storeID])
        XCTAssertEqual(detachCallCount, 1, "live tabs must be detached exactly once, before the wipe")
        XCTAssertTrue(gatedDuringHook, "resolution is gated from the detach hook onward")
        XCTAssertTrue(registry.sites.isEmpty)
        XCTAssertNil(registry.store(for: URL(string: "https://app.example.com")!))
    }

    @MainActor
    func testClearAllRetainedDataDetachesKeepsChoicesAndReResolvesAfterwards() {
        let directory = makeRegistryDirectory()
        let registry = MacSiteMemoryRegistry(directory: directory)
        _ = registry.remember(url: URL(string: "https://a.example.com")!)
        _ = registry.remember(url: URL(string: "https://b.example.com")!)
        let storeIDs = Set(registry.sites.map(\.storeID))
        var invalidated: Set<UUID> = []
        var gatedDuringHook = false
        registry.onJarsInvalidated = { [weak registry] ids in
            invalidated = ids
            if let registry {
                gatedDuringHook = registry.store(for: URL(string: "https://a.example.com")!) == nil
            }
        }

        let expectation = self.expectation(description: "clearAll")
        Task {
            await registry.clearAllRetainedData()
            expectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        XCTAssertEqual(invalidated, storeIDs, "clearing retained data detaches live tabs too")
        XCTAssertTrue(gatedDuringHook)
        // Choices are retained and resolve to their (now empty) jars again.
        XCTAssertEqual(registry.sites.count, 2)
        XCTAssertNotNil(registry.store(for: URL(string: "https://a.example.com")!))
    }

    @MainActor
    func testForgetAllDetachesEveryJarBeforeWiping() {
        let directory = makeRegistryDirectory()
        let registry = MacSiteMemoryRegistry(directory: directory)
        _ = registry.remember(url: URL(string: "https://a.example.com")!)
        _ = registry.remember(url: URL(string: "https://b.example.com")!)
        let storeIDs = Set(registry.sites.map(\.storeID))
        var invalidated: Set<UUID> = []
        registry.onJarsInvalidated = { invalidated = $0 }

        let expectation = self.expectation(description: "forgetAll")
        Task {
            await registry.forgetAll()
            expectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        XCTAssertEqual(invalidated, storeIDs)
        XCTAssertTrue(registry.sites.isEmpty)
    }

    @MainActor
    func testRegistryPersistsAcrossForget() {
        let directory = makeRegistryDirectory()
        let registry = MacSiteMemoryRegistry(directory: directory)
        _ = registry.remember(url: URL(string: "https://a.example.com")!)
        _ = registry.remember(url: URL(string: "https://b.example.com")!)

        let expectation = self.expectation(description: "forget")
        Task {
            await registry.forget(origin: "https://a.example.com")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 30)
        registry.flush()

        let reloaded = MacSiteMemoryRegistry(directory: directory)
        XCTAssertEqual(reloaded.sites.map(\.origin), ["https://b.example.com"])
    }
}

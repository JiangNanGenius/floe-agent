// SPDX-License-Identifier: MPL-2.0
import XCTest
import CryptoKit
import FloeCore
@testable import FloeApp

@MainActor
final class HelpContentCenterTests: XCTestCase {
    private func files() throws -> [String: Data] {
        if let path = ProcessInfo.processInfo.environment["FLOE_HELP_FIXTURE_ROOT"] {
            return try HelpContentCenter.readBundledFiles(at: URL(fileURLWithPath: path, isDirectory: true))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FloeApp/Resources/Help", isDirectory: true)
        return try HelpContentCenter.readBundledFiles(at: root)
    }

    private func package(_ version: String, title: String? = nil) throws -> HelpContentPackage {
        var payload = try files()
        var manifest = try JSONDecoder().decode(HelpPackageManifest.self,
            from: XCTUnwrap(payload[HelpBundleMetadata.manifestPath]))
        manifest.version = version
        if let title { manifest.title["en"] = title }
        payload[HelpBundleMetadata.manifestPath] = try JSONEncoder().encode(manifest)
        var content = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(payload["content.json"])) as? [String: Any])
        content["version"] = version
        payload["content.json"] = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        return HelpContentPackage(version: version, files: payload)
    }

    private func center(installed: @escaping @MainActor () -> HelpContentPackage?,
                        load: @escaping @MainActor () async -> Void = {}) throws -> HelpContentCenter {
        let bundled = try files()
        return HelpContentCenter(bundledFiles: { bundled }, installedPackage: installed,
            awaitInitialLoad: load,
            compareVersions: { lhs, rhs in
                // The center delegates comparison. The integration uses the
                // signed updater's comparator; this fixture orders test input.
                lhs.compare(rhs, options: .numeric)
            }, digest: { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
    }

    func testInstalledNewerSurvivesAnOlderAppBundle() async throws {
        let installed = try package("2.0.0")
        let center = try center(installed: { installed })
        await center.prepare()
        XCTAssertEqual(center.selectedVersion, "2.0.0")
        XCTAssertEqual(try center.snapshot(language: .simplifiedChinese).manifest.version, "2.0.0")
    }

    func testEqualVersionKeepsInstalledAndStrictlyNewerBundleTakesOver() async throws {
        let equal = try package(HelpBundleMetadata.bundledVersion, title: "Installed guide")
        let installedCenter = try center(installed: { equal })
        await installedCenter.prepare()
        XCTAssertEqual(try installedCenter.snapshot(language: .english).manifest.title["en"], "Installed guide")
        let older = try package("1.0.0")
        let upgraded = try center(installed: { older })
        await upgraded.prepare()
        XCTAssertEqual(upgraded.selectedVersion, HelpBundleMetadata.bundledVersion)
    }

    func testPrepareJoinsInitialLoadBeforeExposingBundledContent() async throws {
        let gate = HelpLoadTestGate()
        let newer = try package("2.0.0")
        let state = HelpInstallationTestState()
        let center = try center(installed: { state.package }, load: {
            state.initialLoads += 1
            await gate.wait()
            state.package = newer
        })
        let first = Task { await center.prepare() }
        let second = Task { await center.prepare() }
        await Task.yield()
        XCTAssertFalse(center.isPrepared)
        XCTAssertNil(center.selectedVersion)
        XCTAssertThrowsError(try center.snapshot(language: .english)) {
            XCTAssertEqual($0 as? HelpContentError, .preparing)
        }
        await gate.open()
        await first.value
        await second.value
        XCTAssertEqual(state.initialLoads, 1)
        XCTAssertEqual(center.selectedVersion, "2.0.0")
    }

    func testUpdateRetainsExactReferencesAndRejectsCorruptSuccessor() async throws {
        let state = HelpInstallationTestState(package: try package("2.0.0"))
        let center = try center(installed: { state.package })
        await center.prepare()
        let snapshot = try center.snapshot(language: .english)
        let article = try XCTUnwrap(snapshot.index.articles.first)
        let old = try snapshot.reference(articleID: article.id)
        let original = try center.read(old)
        state.package = try package("2.1.0")
        center.reload()
        XCTAssertEqual(center.selectedVersion, "2.1.0")
        XCTAssertEqual(try center.read(old), original)
        var corrupt = try package("2.2.0").files
        corrupt[article.htmlPath] = Data("corrupt".utf8)
        state.package = HelpContentPackage(version: "2.2.0", files: corrupt)
        center.reload()
        XCTAssertEqual(center.selectedVersion, "2.1.0")
        XCTAssertNotNil(center.errorMessage)
        XCTAssertEqual(try center.read(old), original)
    }

    func testEvictedReferenceFailsInsteadOfSilentlyReadingNewVersion() async throws {
        let state = HelpInstallationTestState(package: try package("2.0.0"))
        let center = try center(installed: { state.package })
        await center.prepare()
        let snapshot = try center.snapshot(language: .english)
        let reference = try snapshot.reference(articleID: XCTUnwrap(snapshot.index.articles.first).id)
        for minor in 1...4 {
            state.package = try package("2.\(minor).0")
            center.reload()
        }
        XCTAssertThrowsError(try center.read(reference)) {
            XCTAssertEqual($0 as? HelpContentError, .expiredReference)
        }
        // A reader already holding an immutable snapshot remains coherent.
        XCTAssertEqual(try snapshot.read(reference).reference.version, "2.0.0")
    }
}

@MainActor
private final class HelpInstallationTestState {
    var package: HelpContentPackage?
    var initialLoads = 0
    init(package: HelpContentPackage? = nil) { self.package = package }
}

private actor HelpLoadTestGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

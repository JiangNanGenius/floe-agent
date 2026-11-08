// SPDX-License-Identifier: MPL-2.0
//
// Android public SkillHub transport-mirror router qualification tests
// (authored, NOT executed by this source-only lane). All request closures
// are bounded anonymous fixtures: no live server, device, App cloud or real
// signing key is touched. Ported in behaviour from the reviewed iOS main
// tests FloeAgent/Tests/FloeSkillsTests/SkillHubMirrorTransportTests.swift
// (main @ 2ce48570a, fixed git object).
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeSkills

final class AndroidHubMirrorTransportTests: XCTestCase, @unchecked Sendable {
    private let pin = "0123456789abcdef0123456789abcdef01234567"
    private var raw: URL { URL(string: "https://raw.githubusercontent.com/JiangNanGenius/floe-skill-hub/\(pin)/catalog-full.json")! }
    private actor Attempts {
        var urls: [URL] = []
        func record(_ url: URL) -> Int { urls.append(url); return urls.count }
        func snapshot() -> [URL] { urls }
    }
    private enum ContentFailure: Error { case signature, digest, oversized }

    func testFixedPathsAndRoleOrder() {
        let paths = AndroidHubMirrorTransport.candidates(for: raw)
        XCTAssertEqual(paths.map(\.host), ["raw.githubusercontent.com", "ghfast.top", "gh-proxy.com"])
        XCTAssertEqual(paths[1].absoluteString, "https://ghfast.top/" + raw.absoluteString)
        XCTAssertEqual(paths[2].absoluteString, "https://gh-proxy.com/" + raw.absoluteString)
        let atom = URL(string: "https://github.com/JiangNanGenius/floe-skill-hub/commits/main.atom")!
        XCTAssertEqual(AndroidHubMirrorTransport.candidates(for: atom).map(\.host), ["github.com", "gh-proxy.com"])
    }

    func testVerifiedRoleDisablesAndReordersOnlyCompiledMirrors() {
        let roles = AndroidHubMirrorRoles(rawFiles: [.ghProxy], atom: [], releaseAssets: [])
        XCTAssertEqual(AndroidHubMirrorTransport.candidates(for: raw, roles: roles).map(\.host),
                       ["raw.githubusercontent.com", "gh-proxy.com"])
        let atom = URL(string: "https://github.com/JiangNanGenius/floe-skill-hub/commits/main.atom")!
        XCTAssertEqual(AndroidHubMirrorTransport.candidates(for: atom, roles: roles), [atom])
    }

    func testProductionHubURLBuilderPreservesVersionBytes() throws {
        let url = try XCTUnwrap(AndroidHubMirrorTransport.rawFileURL(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
            commit: pin, path: "engines/ortie/2.3.0+floe.1/archive.zip"))
        XCTAssertTrue(url.absoluteString.contains("2.3.0%2Bfloe.1"))
        let routes = AndroidHubMirrorTransport.candidates(for: url)
        XCTAssertEqual(routes.count, 3)
        XCTAssertTrue(routes.allSatisfy { $0.absoluteString.hasSuffix("2.3.0%2Bfloe.1/archive.zip") })
    }

    func testRejectsUnapprovedTargetsAndKeepsEncodedVersion() {
        for bad in [
            raw.absoluteString.replacingOccurrences(of: pin, with: "main"),
            raw.absoluteString.replacingOccurrences(of: "floe-skill-hub", with: "other"),
            raw.absoluteString + "?token=not-a-real-token", raw.absoluteString + "#fragment",
            raw.absoluteString.replacingOccurrences(of: "https://", with: "http://"),
            raw.absoluteString.replacingOccurrences(of: "raw.githubusercontent.com", with: "raw.githubusercontent.com:443"),
            raw.absoluteString.replacingOccurrences(of: "raw.githubusercontent.com", with: "user@raw.githubusercontent.com"),
            raw.absoluteString.replacingOccurrences(of: "catalog-full.json", with: "a/%2E%2E/catalog-full.json"),
            raw.absoluteString.replacingOccurrences(of: "catalog-full.json", with: "a%2Fb.json"),
            "https://ghfast.top/" + raw.absoluteString,
        ] {
            XCTAssertTrue(AndroidHubMirrorTransport.candidates(for: URL(string: bad)!).isEmpty, bad)
        }
        let version = URL(string: raw.absoluteString.replacingOccurrences(of: "catalog-full.json", with: "engines/ortie/dist/ortie-2.3.0%2Bfloe.1.0.0/aarch64-unknown-linux-musl/floe-ortie"))!
        XCTAssertEqual(AndroidHubMirrorTransport.candidates(for: version).count, 3)
        XCTAssertTrue(AndroidHubMirrorTransport.candidates(for: version)[1].absoluteString.contains("%2B"))
    }

    func testAvailabilityClassificationExcludesAccessIntegrityAndTLS() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(AndroidHubMirrorTransport.isAvailabilityFailure(AndroidHubMirrorTransport.Failure.httpStatus(code)))
        }
        for code in [200, 301, 302, 307, 400, 401, 403, 404, 410, 416] {
            XCTAssertFalse(AndroidHubMirrorTransport.isAvailabilityFailure(AndroidHubMirrorTransport.Failure.httpStatus(code)))
        }
        for code in [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertTrue(AndroidHubMirrorTransport.isAvailabilityFailure(URLError(code)))
        }
        for error: Error in [CancellationError(), URLError(.cancelled), URLError(.cannotLoadFromNetwork), URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed), ContentFailure.signature, ContentFailure.digest, ContentFailure.oversized] {
            XCTAssertFalse(AndroidHubMirrorTransport.isAvailabilityFailure(error))
        }
    }

    func testAvailabilityFailureTraversesOnlyTheSamePinnedFile() async throws {
        let attempts = Attempts()
        let data = try await AndroidHubMirrorTransport.load(raw) { url in
            switch await attempts.record(url) {
            case 1: throw URLError(.timedOut)
            case 2: throw AndroidHubMirrorTransport.Failure.httpStatus(503)
            default: return Data("signed bytes".utf8)
            }
        }
        XCTAssertEqual(data, Data("signed bytes".utf8))
        let urls = await attempts.snapshot()
        XCTAssertEqual(urls, AndroidHubMirrorTransport.candidates(for: raw))
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains(self.pin + "/catalog-full.json") })
    }

    func testContentAndPermissionFailuresNeverAdvanceRoute() async {
        for error: Error in [ContentFailure.signature, ContentFailure.digest, ContentFailure.oversized, AndroidHubMirrorTransport.Failure.httpStatus(403), CancellationError()] {
            let attempts = Attempts()
            do {
                _ = try await AndroidHubMirrorTransport.load(raw) { url in
                    _ = await attempts.record(url); throw error
                }
                XCTFail("expected refusal")
            } catch {}
            let urls = await attempts.snapshot(); XCTAssertEqual(urls.count, 1)
        }
    }

    func testCacheOnlyNetworkRefusalDoesNotRequestAMirror() async {
        let attempts = Attempts()
        do {
            _ = try await AndroidHubMirrorTransport.load(raw) { url in
                _ = await attempts.record(url)
                throw URLError(.cannotLoadFromNetwork)
            }
            XCTFail("expected original cache policy refusal")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotLoadFromNetwork)
        }
        let urls = await attempts.snapshot()
        XCTAssertEqual(urls, [raw])
    }

    func testSuccessfulBytesAreNotInspectedOrRetriedByTransport() async throws {
        let attempts = Attempts()
        let bytes = Data("bad signature body rejected later by existing verifier".utf8)
        let data = try await AndroidHubMirrorTransport.load(raw) { url in
            _ = await attempts.record(url); return bytes
        }
        XCTAssertEqual(data, bytes)
        let urls = await attempts.snapshot(); XCTAssertEqual(urls.count, 1)
    }

    func testInvalidTargetNeverRequestsAnything() async {
        let attempts = Attempts()
        do {
            _ = try await AndroidHubMirrorTransport.load(URL(string: "https://example.invalid/catalog-full.json")!) { url in
                _ = await attempts.record(url); return Data()
            }
            XCTFail("expected invalid target")
        } catch { XCTAssertEqual(error as? AndroidHubMirrorTransport.Failure, .invalidTarget) }
        let urls = await attempts.snapshot(); XCTAssertTrue(urls.isEmpty)
    }

    func testAvailabilityExhaustionStopsAtLastApprovedRoute() async {
        let attempts = Attempts()
        do {
            _ = try await AndroidHubMirrorTransport.load(raw) { url in
                _ = await attempts.record(url); throw URLError(.cannotConnectToHost)
            }
            XCTFail("expected unavailable")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        let urls = await attempts.snapshot(); XCTAssertEqual(urls.count, 3)
    }

    func testCancellationAfterResponseDiscardsBytesWithoutFailover() async {
        let attempts = Attempts(); let url = raw
        let task = Task {
            try await AndroidHubMirrorTransport.load(url) { target in
                _ = await attempts.record(target)
                withUnsafeCurrentTask { $0?.cancel() }
                return Data("late bytes".utf8)
            }
        }
        do { _ = try await task.value; XCTFail("expected cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let urls = await attempts.snapshot(); XCTAssertEqual(urls.count, 1)
    }
}

import Foundation
import XCTest
@testable import FloeSkills

final class ElectronicsLibraryMirrorTransportTests: XCTestCase, @unchecked Sendable {
    private let pin = "0123456789abcdef0123456789abcdef01234567"
    private var release: URL {
        URL(string: "https://github.com/JiangNanGenius/floe-electronics-library/releases/download/data-v1-0123456789abcdef0123/catalog.json")!
    }
    private var dataRaw: URL {
        URL(string: "https://raw.githubusercontent.com/JiangNanGenius/floe-electronics-library/\(pin)/indexes/lib-a.jsonl.gz")!
    }
    private var modelRaw: URL {
        URL(string: "https://raw.githubusercontent.com/KiCad/kicad-packages3D/\(pin)/Resistor_SMD.3dshapes/R_0603_1608Metric.step")!
    }
    private var gitlab: URL {
        URL(string: "https://gitlab.com/kicad/libraries/kicad-packages3D/-/raw/\(pin)/Resistor_SMD.3dshapes/R_0603_1608Metric.step")!
    }
    private var realPathRaw: URL {
        URL(string: "https://raw.githubusercontent.com/KiCad/kicad-packages3D/\(pin)/Connector_Phoenix_GMSTB.3dshapes/PhoenixContact_GMSTBA_2%2C5_10-G-7%2C62_1x10_P7.62mm_Horizontal.step")!
    }

    func testFixedRoutesAndSignedRoleOrder() {
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: release).map(\.host), ["github.com"])
        let releaseRoles = GitHubTransportMirrorRoles(rawFiles: [], atom: [], releaseAssets: [.ghProxy])
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: release, roles: releaseRoles).map(\.host),
                       ["github.com", "gh-proxy.com"])

        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: dataRaw).map(\.host),
                       ["raw.githubusercontent.com", "ghfast.top", "gh-proxy.com"])
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: modelRaw).map(\.host),
                       ["raw.githubusercontent.com", "ghfast.top", "gh-proxy.com"])
        let rawRoles = GitHubTransportMirrorRoles(rawFiles: [.ghProxy], atom: [], releaseAssets: [])
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: dataRaw, roles: rawRoles).map(\.host),
                       ["raw.githubusercontent.com", "gh-proxy.com"])
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: dataRaw,
            roles: GitHubTransportMirrorRoles(rawFiles: [], atom: [], releaseAssets: [])).map(\.host),
                       ["raw.githubusercontent.com"])
    }

    func testLatestReceiptAndGitLabCanonicalNeverUseGitHubProxies() {
        let latest = URL(string: ElectronicsLibraryMirrorTransport.latestReceiptURLString)!
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: latest).map(\.absoluteString),
                       [latest.absoluteString])
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: gitlab).map(\.absoluteString),
                       [gitlab.absoluteString])
    }

    func testRealCommaSpaceParenthesisPathIsAccepted() {
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: realPathRaw).map(\.host),
                       ["raw.githubusercontent.com", "ghfast.top", "gh-proxy.com"])
        XCTAssertTrue(realPathRaw.absoluteString.contains("%2C"))
        let spacesAndParentheses = URL(string: "https://raw.githubusercontent.com/sparkfun/SparkFun-KiCad-Libraries/\(pin)/3dmodels/Board.3dshapes/Arduino%20Pro%20Mini%20%28Pins%29.step")!
        XCTAssertEqual(ElectronicsLibraryMirrorTransport.candidates(for: spacesAndParentheses).map(\.host),
                       ["raw.githubusercontent.com", "ghfast.top", "gh-proxy.com"])
        XCTAssertTrue(spacesAndParentheses.absoluteString.contains("%28"))
        XCTAssertTrue(spacesAndParentheses.absoluteString.contains("%20"))
    }

    func testRejectsTraversalDoubleEncodingAndUnapprovedTargets() {
        let bad = [
            dataRaw.absoluteString.replacingOccurrences(of: pin, with: "main"),
            dataRaw.absoluteString.replacingOccurrences(of: "floe-electronics-library", with: "other"),
            dataRaw.absoluteString + "?token=x",
            dataRaw.absoluteString + "#fragment",
            dataRaw.absoluteString.replacingOccurrences(of: "https://", with: "http://"),
            dataRaw.absoluteString.replacingOccurrences(of: "raw.githubusercontent.com", with: "raw.githubusercontent.com:443"),
            dataRaw.absoluteString.replacingOccurrences(of: "raw.githubusercontent.com", with: "user@raw.githubusercontent.com"),
            "https://ghfast.top/" + dataRaw.absoluteString,
            "https://evil.invalid/JiangNanGenius/floe-electronics-library/\(pin)/x.json",
            gitlab.absoluteString.replacingOccurrences(of: "kicad-packages3D", with: "other"),
            realPathRaw.absoluteString.replacingOccurrences(of: "%2C", with: "%252C"),
            realPathRaw.absoluteString.replacingOccurrences(of: "%2C", with: "%2F"),
            realPathRaw.absoluteString.replacingOccurrences(of: "Horizontal.step", with: "..%2Fescape.step"),
            "https://raw.githubusercontent.com/LibrePCB-Libraries/Evil/\(pin)/x.lp"
        ]
        for value in bad {
            XCTAssertTrue(ElectronicsLibraryMirrorTransport.candidates(for: URL(string: value)!).isEmpty, value)
        }
        // The exact release tag and a flat asset name are required.
        XCTAssertTrue(ElectronicsLibraryMirrorTransport.candidates(
            for: URL(string: release.absoluteString.replacingOccurrences(of: "data-v1-", with: "main-"))!).isEmpty)
        XCTAssertTrue(ElectronicsLibraryMirrorTransport.candidates(
            for: URL(string: release.absoluteString.replacingOccurrences(of: "catalog.json", with: "nested/catalog.json"))!).isEmpty)
    }

    func testAvailabilityClassificationExcludesAccessAndIntegrity() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(ElectronicsLibraryMirrorTransport.isAvailabilityFailure(
                ElectronicsLibraryMirrorTransport.Failure.httpStatus(code)))
        }
        for code in [200, 301, 302, 307, 400, 401, 403, 404, 410, 416] {
            XCTAssertFalse(ElectronicsLibraryMirrorTransport.isAvailabilityFailure(
                ElectronicsLibraryMirrorTransport.Failure.httpStatus(code)))
        }
        for code in [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                     .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertTrue(ElectronicsLibraryMirrorTransport.isAvailabilityFailure(URLError(code)))
        }
        for error: Error in [CancellationError(), URLError(.cancelled), URLError(.cannotLoadFromNetwork),
                             URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed),
                             ElectronicsLibraryMirrorTransport.Failure.invalidTarget,
                             ElectronicsRemoteTestFailure.digest] {
            XCTAssertFalse(ElectronicsLibraryMirrorTransport.isAvailabilityFailure(error))
        }
    }

    func testAvailabilityOnlyFallbackKeepsTheSamePinnedFile() async throws {
        let attempts = Attempts()
        let data = try await ElectronicsLibraryMirrorTransport.load(realPathRaw) { url in
            switch await attempts.record(url) {
            case 1: throw URLError(.timedOut)
            case 2: throw ElectronicsLibraryMirrorTransport.Failure.httpStatus(503)
            default: return Data("verified bytes".utf8)
            }
        }
        XCTAssertEqual(data, Data("verified bytes".utf8))
        let urls = await attempts.snapshot()
        XCTAssertEqual(urls, ElectronicsLibraryMirrorTransport.candidates(for: realPathRaw))
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains(self.pin + "/Connector_Phoenix") })
    }

    func testIntegrityFailureStopsAfterCanonicalAndCancellationStops() async throws {
        let attempts = Attempts()
        do {
            _ = try await ElectronicsLibraryMirrorTransport.load(dataRaw) { url in
                _ = await attempts.record(url)
                throw ElectronicsRemoteTestFailure.digest
            }
            XCTFail("integrity failure must not retry")
        } catch ElectronicsRemoteTestFailure.digest {}
        let integrityAttempts = await attempts.snapshot()
        XCTAssertEqual(integrityAttempts.count, 1)

        let cancelled = Task {
            try await ElectronicsLibraryMirrorTransport.load(dataRaw) { _ in
                try Task.checkCancellation()
                return Data()
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled transfer must not succeed")
        } catch is CancellationError {
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }

    private actor Attempts {
        private var urls: [URL] = []
        func record(_ url: URL) -> Int { urls.append(url); return urls.count }
        func snapshot() -> [URL] { urls }
    }

    private enum ElectronicsRemoteTestFailure: Error {
        case digest
    }
}
